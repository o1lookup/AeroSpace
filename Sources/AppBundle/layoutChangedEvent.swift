import AppKit
import Common

// Fork: `layout-changed` event of `aerospace subscribe`.
//
// Pushed after every layout pass and on window title changes, with everything an external overlay needs
// to paint i3-style title bars (see `title-bar-height`, `list-title-bars`) and a workspace bar.
// It lets the overlay react immediately instead of polling `list-*` commands.
// The event is sent only when the snapshot differs from the previously sent one.

struct LayoutSnapshotJson: Codable, Sendable, Equatable {
    let focusedWindowId: UInt32?
    let focusedWorkspace: String
    let monitors: [LayoutMonitorJson]
    /// Visible workspaces and non-empty invisible workspaces
    let workspaces: [LayoutWorkspaceJson]
    let titleBars: [TitleBarJson]

    enum CodingKeys: String, CodingKey {
        case monitors, workspaces
        case focusedWindowId = "focused-window-id"
        case focusedWorkspace = "focused-workspace"
        case titleBars = "title-bars"
    }
}

struct LayoutMonitorJson: Codable, Sendable, Equatable {
    let monitorId: Int? // 1-based
    let monitorName: String
    let visibleWorkspace: String

    enum CodingKeys: String, CodingKey {
        case monitorId = "monitor-id"
        case monitorName = "monitor-name"
        case visibleWorkspace = "visible-workspace"
    }
}

struct LayoutWorkspaceJson: Codable, Sendable, Equatable {
    let workspace: String
    let monitorId: Int? // 1-based
    let isVisible: Bool
    let windows: [LayoutWindowJson] // Tree order

    enum CodingKeys: String, CodingKey {
        case workspace, windows
        case monitorId = "monitor-id"
        case isVisible = "is-visible"
    }
}

struct LayoutWindowJson: Codable, Sendable, Equatable {
    let windowId: UInt32
    let appName: String?
    let appBundleId: String?
    let appPid: Int32
    let title: String? // Only for windows of visible workspaces (fetching titles costs AX calls)
    let parentContainerId: Int64?
    let parentLayout: String // h_tiles | v_tiles | h_accordion | v_accordion | floating
    let isFullscreen: Bool

    enum CodingKeys: String, CodingKey {
        case title
        case windowId = "window-id"
        case appName = "app-name"
        case appBundleId = "app-bundle-id"
        case appPid = "app-pid"
        case parentContainerId = "parent-container-id"
        case parentLayout = "parent-layout"
        case isFullscreen = "is-fullscreen"
    }
}

@MainActor private var lastSentLayoutSnapshot: LayoutSnapshotJson? = nil
@MainActor private var layoutBroadcastInFlight = false
@MainActor private var layoutBroadcastPending = false

/// The next pass sends the snapshot even if it equals the last sent one (e.g. a subscriber just connected)
@MainActor
func forceLayoutChangedBroadcast() {
    lastSentLayoutSnapshot = nil
    scheduleLayoutChangedBroadcast()
}

/// Coalescing: at most one snapshot is being built at a time; changes that happen meanwhile trigger one more pass
@MainActor
func scheduleLayoutChangedBroadcast() {
    guard hasSubscribers(for: .layoutChanged) else {
        lastSentLayoutSnapshot = nil
        return
    }
    if layoutBroadcastInFlight {
        layoutBroadcastPending = true
        return
    }
    layoutBroadcastInFlight = true
    Task.startUnstructured { @MainActor in
        defer { layoutBroadcastInFlight = false }
        repeat {
            layoutBroadcastPending = false
            let snapshot = await buildLayoutSnapshot()
            if snapshot != lastSentLayoutSnapshot {
                lastSentLayoutSnapshot = snapshot
                broadcastEvent(.layoutChanged(snapshot))
            }
        } while layoutBroadcastPending
    }
}

@MainActor
func buildLayoutSnapshot() async -> LayoutSnapshotJson {
    // Capture the tree synchronously; titles are fetched afterwards (suspension points)
    let f = focus
    var titleBars: [TitleBarJson] = []
    var workspaceEntries: [(workspace: Workspace, windows: [Window])] = []
    for workspace in Workspace.all {
        let windows = workspace.allLeafWindowsRecursive.filter(\.isBound)
        if windows.isEmpty && !workspace.isVisible { continue }
        workspaceEntries.append((workspace, windows))
        if workspace.isVisible {
            collectTitleBars(workspace.rootTilingContainer, workspace: workspace.name, focusedWindow: f.windowOrNil, into: &titleBars)
        }
    }
    let monitorsJson = monitors.map {
        LayoutMonitorJson(monitorId: $0.monitorId_oneBased, monitorName: $0.name, visibleWorkspace: $0.activeWorkspace.name)
    }
    var workspacesJson: [LayoutWorkspaceJson] = []
    for (workspace, windows) in workspaceEntries {
        var windowsJson: [LayoutWindowJson] = []
        for window in windows {
            let title: String? = workspace.isVisible ? await cachedTitle(window) : nil
            windowsJson.append(LayoutWindowJson(
                windowId: window.windowId,
                appName: window.app.name,
                appBundleId: window.app.rawAppBundleId,
                appPid: window.app.pid,
                title: title,
                parentContainerId: window.parent.map(treeNodeId),
                parentLayout: (window.parent as? TilingContainer).map { toLayoutString(tc: $0) } ?? "floating",
                isFullscreen: window.isFullscreen,
            ))
        }
        workspacesJson.append(LayoutWorkspaceJson(
            workspace: workspace.name,
            monitorId: workspace.workspaceMonitor.monitorId_oneBased,
            isVisible: workspace.isVisible,
            windows: windowsJson,
        ))
    }
    let aliveWindowIds = Set(workspaceEntries.flatMap { $0.windows.map(\.windowId) })
    titleCache = titleCache.filter { aliveWindowIds.contains($0.key) }
    dirtyTitles.formIntersection(aliveWindowIds)
    return LayoutSnapshotJson(
        focusedWindowId: f.windowOrNil?.windowId,
        focusedWorkspace: f.workspace.name,
        monitors: monitorsJson,
        workspaces: workspacesJson,
        titleBars: titleBars,
    )
}

// Window titles. Fetching a title is an AX call into the app, so:
// - titles are cached and re-fetched only when the app reported a title change (`dirtyTitles`) or the cache is old
//   (some apps don't support kAXTitleChangedNotification)
// - a fetch never blocks the snapshot for longer than `titleFetchTimeout`: an unresponsive app can't wedge the
//   push mechanism. A late title is pushed with one more broadcast when it finally arrives
@MainActor private var titleCache: [UInt32: (title: String, fetchedAt: Date)] = [:]
@MainActor private var dirtyTitles: Set<UInt32> = []
@MainActor private var titleFetchInFlight: Set<UInt32> = []
@MainActor private var titleChangeBroadcastScheduled = false
private let titleCacheTtl: TimeInterval = 5
private let titleFetchTimeout: Duration = .milliseconds(300)
private let titleChangeDebounce: Duration = .milliseconds(150)

@MainActor
private func cachedTitle(_ window: Window) async -> String {
    let id = window.windowId
    let cached = titleCache[id]
    let isFresh = cached.map { !dirtyTitles.contains(id) && Date().timeIntervalSince($0.fetchedAt) < titleCacheTtl } ?? false
    if isFresh || titleFetchInFlight.contains(id) { return cached?.title ?? "" }
    titleFetchInFlight.insert(id)
    dirtyTitles.remove(id)
    return await withCheckedContinuation { (cont: CheckedContinuation<String, Never>) in
        let once = ResumeOnce(cont)
        Task.startUnstructured { @MainActor in
            let title = (try? await window.getTitle(.cancellable)) ?? cached?.title ?? ""
            titleFetchInFlight.remove(id)
            titleCache[id] = (title, Date())
            if !once.resume(title) { scheduleLayoutChangedBroadcast() } // Arrived after the timeout: push it now
        }
        Task.startUnstructured { @MainActor in
            try? await Task.sleep(for: titleFetchTimeout)
            once.resume(cached?.title ?? "")
        }
    }
}

@MainActor
private final class ResumeOnce {
    private var continuation: CheckedContinuation<String, Never>?
    init(_ continuation: CheckedContinuation<String, Never>) { self.continuation = continuation }
    /// Returns false if already resumed
    @discardableResult
    func resume(_ value: String) -> Bool {
        guard let continuation else { return false }
        self.continuation = nil
        continuation.resume(returning: value)
        return true
    }
}

/// AX observer for kAXTitleChangedNotification (subscribed optionally, see AxSubscription.optionalSubscribe).
/// Debounced: apps that update titles many times per second (terminals, progress) cause one broadcast per debounce period
func titleChangedObs(_: AXObserver, ax: AXUIElement, notif _: CFString, _: UnsafeMutableRawPointer?) {
    let windowId = ax.containingWindowId()
    Task.startUnstructured { @MainActor in
        if let windowId { dirtyTitles.insert(windowId) }
        if titleChangeBroadcastScheduled { return }
        titleChangeBroadcastScheduled = true
        try? await Task.sleep(for: titleChangeDebounce)
        titleChangeBroadcastScheduled = false
        scheduleLayoutChangedBroadcast()
    }
}
