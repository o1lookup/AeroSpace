// Fork: i3-style title bars. See docs/aerospace-list-title-bars.adoc
public struct ListTitleBarsCmdArgs: CmdArgs {
    /*conforms*/ public var commonState: CmdArgsCommonState
    public init(rawArgs: StrArrSlice) {
        self.commonState = .init(rawArgs)
    }
    public static let parser: CmdParser<Self> = .init(
        kind: .listTitleBars,
        help: list_title_bars_help_generated,
        flags: [:],
        posArgs: [],
    )
}

func parseListTitleBarsCmdArgs(_ args: StrArrSlice) -> ParsedCmd<ListTitleBarsCmdArgs> {
    parseSpecificCmdArgs(ListTitleBarsCmdArgs(rawArgs: args), args)
}
