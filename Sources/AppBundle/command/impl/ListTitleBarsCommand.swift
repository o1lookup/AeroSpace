import AppKit
import Common

/// Fork: i3-style title bars. Dumps the title rects reserved by the layout engine (`title-bar-height > 0`)
/// on visible workspaces, so that an external overlay can paint the titles.
struct ListTitleBarsCommand: Command {
    let args: ListTitleBarsCmdArgs
    /*conforms*/ let shouldResetClosedWindowsCache = false

    func run(_ env: CmdEnv, _ io: CmdIo) -> BinaryExitCode {
        let focusedWindow = focus.windowOrNil
        var result: [TitleBarJson] = []
        for workspace in Workspace.all where workspace.isVisible {
            collectTitleBars(workspace.rootTilingContainer, workspace: workspace.name, focusedWindow: focusedWindow, into: &result)
        }
        return JSONEncoder.aeroSpaceDefault.encodeToString(result).map { .succ(io.out($0)) }
            ?? .fail(io.err("Failed to encode JSON"))
    }
}

@MainActor
private func collectTitleBars(_ node: TreeNode, workspace: String, focusedWindow: Window?, into result: inout [TitleBarJson]) {
    if let rect = node.lastAppliedTitleRect, let parent = node.parent as? TilingContainer {
        let window = node as? Window
        let container = node as? TilingContainer
        result.append(TitleBarJson(
            workspace: workspace,
            kind: window != nil ? "window" : "container",
            windowId: window?.windowId,
            containerId: container.map(treeNodeId),
            containerLayout: container.map { toLayoutString(tc: $0) },
            leafWindowIds: container.map { $0.allLeafWindowsRecursive.map(\.windowId) },
            parentContainerId: treeNodeId(parent),
            parentLayout: toLayoutString(tc: parent),
            index: node.ownIndex ?? 0,
            isMostRecent: parent.mostRecentChild === node,
            isFocused: focusedWindow?.parentsWithSelf.contains(where: { ancestor in ancestor === node }) ?? false,
            x: rect.topLeftX,
            y: rect.topLeftY,
            width: rect.width,
            height: rect.height,
        ))
    }
    for child in node.children where child is TilingContainer || child is Window {
        collectTitleBars(child, workspace: workspace, focusedWindow: focusedWindow, into: &result)
    }
}

/// Process-stable identity of a tree node (not persistent across AeroSpace restarts).
/// The same value as `%{window-parent-container-id}` for the window's parent
func treeNodeId(_ node: TreeNode) -> Int64 { Int64(ObjectIdentifier(node).hashValue) }

private struct TitleBarJson: Encodable {
    let workspace: String
    let kind: String // "window" | "container"
    let windowId: UInt32?
    let containerId: Int64?
    let containerLayout: String?
    let leafWindowIds: [UInt32]?
    let parentContainerId: Int64
    let parentLayout: String
    let index: Int
    let isMostRecent: Bool
    let isFocused: Bool
    let x: CGFloat
    let y: CGFloat
    let width: CGFloat
    let height: CGFloat

    enum CodingKeys: String, CodingKey {
        case workspace, kind, index, x, y, width, height
        case windowId = "window-id"
        case containerId = "container-id"
        case containerLayout = "container-layout"
        case leafWindowIds = "leaf-window-ids"
        case parentContainerId = "parent-container-id"
        case parentLayout = "parent-layout"
        case isMostRecent = "is-most-recent"
        case isFocused = "is-focused"
    }
}
