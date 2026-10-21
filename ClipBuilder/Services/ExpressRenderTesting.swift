/// Reference routes are available only in Debug tests, never a user setting.
nonisolated enum ExpressRenderTesting {
    #if DEBUG
    @TaskLocal static var twoPassExtract = false
    @TaskLocal static var exportAreaPaths = false
    #else
    static let twoPassExtract = false
    static let exportAreaPaths = false
    #endif
}
