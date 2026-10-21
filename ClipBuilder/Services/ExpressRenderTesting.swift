/// Reference routes are available only in Debug tests, never a user setting.
nonisolated enum ExpressRenderTesting {
    #if DEBUG
    @TaskLocal static var twoPassExtract = false
    @TaskLocal static var exportAreaPaths = false
    // Override immutable launch flags without mutating the process environment
    // while Swift Testing runs fixtures concurrently.
    @TaskLocal static var hardwareDecodeIntermediates: Bool?
    #else
    static let twoPassExtract = false
    static let exportAreaPaths = false
    static let hardwareDecodeIntermediates: Bool? = nil
    #endif
}
