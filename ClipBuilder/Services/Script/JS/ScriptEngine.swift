import Foundation
import JavaScriptCore
import Darwin

// ABI from WebKit Source/JavaScriptCore/API/JSContextRefPrivate.h:
// typedef bool (*JSShouldTerminateCallback)(JSContextRef ctx, void* context);
// void JSContextGroupSetExecutionTimeLimit(JSContextGroupRef group, double limit,
//                                        JSShouldTerminateCallback callback, void* context);
typealias ScriptShouldTerminateCallback = @convention(c) (JSContextRef?, UnsafeMutableRawPointer?) -> Bool

@_silgen_name("JSContextGroupSetExecutionTimeLimit")
nonisolated private func scriptSetExecutionTimeLimit(
    _ group: JSContextGroupRef?, _ limit: Double,
    _ callback: ScriptShouldTerminateCallback?, _ context: UnsafeMutableRawPointer?
)

// Resolve rather than strongly link the private symbol, so an OS without it
// disables this feature instead of preventing the application from launching.
private typealias ScriptSetLimitFunction = @convention(c) (
    JSContextGroupRef?, Double, ScriptShouldTerminateCallback?, UnsafeMutableRawPointer?
) -> Void

private typealias ScriptClearLimitFunction = @convention(c) (JSContextGroupRef?) -> Void

nonisolated private enum ScriptTimeLimitAPI {
    static let clear: ScriptClearLimitFunction? = {
        guard let symbol = dlsym(UnsafeMutableRawPointer(bitPattern: -2), "JSContextGroupClearExecutionTimeLimit") else { return nil }
        return unsafeBitCast(symbol, to: ScriptClearLimitFunction.self)
    }()
    static let set: ScriptSetLimitFunction? = {
        guard let symbol = dlsym(UnsafeMutableRawPointer(bitPattern: -2), "JSContextGroupSetExecutionTimeLimit") else { return nil }
        return unsafeBitCast(symbol, to: ScriptSetLimitFunction.self)
    }()
}

/// Worker-owned callback payload; the C callback never inspects a JS object.
nonisolated private final class ScriptTimeLimitContext {
    let group: JSContextGroupRef?
    let control: ScriptExecutionControl
    init(group: JSContextGroupRef?, control: ScriptExecutionControl) {
        self.group = group
        self.control = control
    }
}

/// Re-arm explicitly on a false callback. This is supported by the private
/// header and avoids depending on a particular WebKit build's repeat behavior.
nonisolated private func scriptShouldTerminate(_: JSContextRef?, _ pointer: UnsafeMutableRawPointer?) -> Bool {
    guard let pointer else { return true }
    let state = Unmanaged<ScriptTimeLimitContext>.fromOpaque(pointer).takeUnretainedValue()
    if state.control.reason != nil { return true }
    ScriptTimeLimitAPI.set?(state.group, 0.005, scriptShouldTerminate, pointer)
    return false
}

nonisolated struct ScriptDiagnostic: Error, Codable, Sendable, Equatable, LocalizedError {
    var code: String
    var reason: String
    var line: Int? = nil
    var column: Int? = nil
    var errorDescription: String? { reason }
}

nonisolated struct ScriptEngineResult: Sendable {
    var summary: Data?
    var diagnostic: ScriptDiagnostic?
}

/// No JS object crosses this boundary. Even final conversion and destruction run
/// inside the worker's autorelease pool, before its continuation is resumed.
nonisolated final class ScriptEngine: Sendable {
    typealias Host = @MainActor @Sendable (String, Data) async -> Data
    static let threadName = "ClipBuilder.JavaScript"
    let control: ScriptExecutionControl
    private let onWorkerBridge: (@Sendable () -> Void)?

    init(seconds: Double = 10, onWorkerBridge: (@Sendable () -> Void)? = nil) {
        control = ScriptExecutionControl(seconds: seconds)
        self.onWorkerBridge = onWorkerBridge
    }
    func cancel() { control.cancel() }

    func evaluate(source: String, bootstrap: String, host: @escaping Host) async -> ScriptEngineResult {
        guard source.utf8.count <= 256 * 1024 else {
            return .init(diagnostic: .init(code: "limit", reason: "Source exceeds 256 KiB."))
        }
        let control = control
        let onWorkerBridge = onWorkerBridge
        return await withTaskCancellationHandler {
            let watchdog = Task {
                while !Task.isCancelled {
                    if let reason = control.reason { control.cancel(reason); return }
                    do { try await Task.sleep(for: .milliseconds(5)) } catch { return }
                }
            }
            let result: ScriptEngineResult = await withCheckedContinuation { continuation in
                let worker = Thread {
                    let result = autoreleasepool {
                        Self.execute(source: source, bootstrap: bootstrap, control: control, host: host, onWorkerBridge: onWorkerBridge)
                    }
                    continuation.resume(returning: result)
                }
                worker.name = Self.threadName
                worker.start()
            }
            watchdog.cancel()
            await watchdog.value
            return result
        } onCancel: { control.cancel() }
    }

    private static func execute(source: String, bootstrap: String, control: ScriptExecutionControl,
                                host: @escaping Host, onWorkerBridge: (@Sendable () -> Void)?) -> ScriptEngineResult {
        precondition(!Thread.isMainThread && Thread.current.name == threadName)
        guard let setTimeLimit = ScriptTimeLimitAPI.set, let clearTimeLimit = ScriptTimeLimitAPI.clear else {
            return .init(diagnostic: .init(code: "unavailable", reason: "JavaScript interruption is unavailable."))
        }
        if let reason = control.reason { return .init(diagnostic: .init(code: reason, reason: reason)) }
        guard let vm = JSVirtualMachine(), let context = JSContext(virtualMachine: vm) else {
            return .init(diagnostic: .init(code: "unavailable", reason: "Could not create JavaScript context."))
        }
        let limitContext = ScriptTimeLimitContext(group: JSContextGetGroup(context.jsGlobalContextRef), control: control)
        defer { clearTimeLimit(limitContext.group); withExtendedLifetime(limitContext) {} }
        let pointer = Unmanaged.passUnretained(limitContext).toOpaque()
        setTimeLimit(limitContext.group, 0.005, scriptShouldTerminate, pointer)
        // The block captures only Sendable host state, never the context or VM.
        let bridge: @convention(block) (String, String) -> String = { name, json in
            precondition(!Thread.isMainThread && Thread.current.name == threadName)
            onWorkerBridge?()
            if let reason = control.reason {
                return "{\"error\":{\"code\":\"\(reason)\",\"reason\":\"Run stopped.\"}}"
            }
            let data = Data(json.utf8)
            guard data.count <= 1024 * 1024 else {
                control.cancel("limit")
                return "{\"error\":{\"code\":\"limit\",\"reason\":\"Arguments exceed 1 MiB.\"}}"
            }
            let latch = ScriptCallLatch()
            control.register(latch)
            let task = Task { @MainActor in
                let result: Data
                if Task.isCancelled {
                    result = Data("{\"error\":{\"code\":\"cancelled\",\"reason\":\"Run cancelled.\"}}".utf8)
                } else { result = await host(name, data) }
                latch.complete(result)
            }
            latch.register(task)
            let result = latch.wait()
            control.clear(latch)
            if let reason = control.reason {
                return "{\"error\":{\"code\":\"\(reason)\",\"reason\":\"Run stopped.\"}}"
            }
            guard result.count <= 1024 * 1024 else {
                control.cancel("limit")
                return "{\"error\":{\"code\":\"limit\",\"reason\":\"Result exceeds 1 MiB.\"}}"
            }
            return String(decoding: result, as: UTF8.self)
        }
        context.setObject(bridge, forKeyedSubscript: "__clipbuilderHost" as NSString)
        _ = context.evaluateScript(bootstrap, withSourceURL: URL(string: "clipbuilder:bridge"))
        if context.exception != nil { return failure(context, control: control, wrapperLines: 0) }
        // Two injected lines. Preserve all source/header lines for diagnostics.
        let wrapped = "(function(){\n\"use strict\";\n" + source + "\n})()"
        let value = context.evaluateScript(wrapped, withSourceURL: URL(string: "clipbuilder:user"))
        if context.exception != nil || control.reason != nil { return failure(context, control: control, wrapperLines: 2) }
        if let value, !value.isUndefined {
            let converted = context.objectForKeyedSubscript("__clipbuilderReturn")?.call(withArguments: [value])
            if context.exception != nil || control.reason != nil { return failure(context, control: control, wrapperLines: 0) }
            guard let json = converted?.toString(), json.utf8.count <= 64 * 1024 else {
                return .init(diagnostic: .init(code: "limit", reason: "Summary exceeds 64 KiB."))
            }
            return .init(summary: Data(json.utf8))
        }
        return .init()
    }

    private static func failure(_ context: JSContext, control: ScriptExecutionControl, wrapperLines: Int) -> ScriptEngineResult {
        if let code = control.reason { return .init(diagnostic: .init(code: code, reason: "Script \(code).")) }
        let error = context.exception
        let name = error?.objectForKeyedSubscript("name")?.toString()
        let suppliedCode = error?.objectForKeyedSubscript("code")
        let code = suppliedCode?.isString == true ? suppliedCode?.toString() : nil
        let reason = error?.toString() ?? "JavaScript failed."
        var line: Int?
        var column: Int?
        let stack = error?.objectForKeyedSubscript("stack")?.toString() ?? ""
        if let range = stack.range(of: #"clipbuilder:user:[0-9]+:[0-9]+"#, options: .regularExpression) {
            let parts = stack[range].split(separator: ":")
            if parts.count == 4, let sourceLine = Int(parts[2]) {
                line = max(1, sourceLine - 2)
                column = Int(parts[3])
            }
        } else if error?.objectForKeyedSubscript("sourceURL")?.toString() == "clipbuilder:user" {
            let sourceLine = error?.objectForKeyedSubscript("line")?.toInt32() ?? 0
            let sourceColumn = error?.objectForKeyedSubscript("column")?.toInt32() ?? 0
            line = sourceLine > 0 ? max(1, Int(sourceLine) - wrapperLines) : nil
            column = sourceColumn > 0 ? Int(sourceColumn) : nil
        }
        if let code = control.reason { return .init(diagnostic: .init(code: code, reason: "Script \(code).")) }
        return .init(diagnostic: .init(code: code ?? (name == "SyntaxError" ? "syntax_error" : "js_error"),
            reason: BuilderRunRedactor().text(reason), line: line, column: column))
    }
}
