import Foundation

nonisolated enum AntigravityResponse {
    enum Failure: Error, Equatable, CustomStringConvertible {
        case cliError(String)
        case deniedTool
        case emptyResponse

        var description: String {
            switch self {
            case .cliError(let message): message
            case .deniedTool: "Antigravity tried to use a tool and was refused by the sandbox."
            case .emptyResponse: "Antigravity returned an empty response."
            }
        }
    }

    static func parse(stdout: String, stderr: String, exitCode: Int32) throws -> String {
        guard let object = (try? JSONSerialization.jsonObject(with: Data(stdout.utf8))) as? [String: Any] else {
            throw Failure.cliError(AIService.firstCLIErrorLine(stderr + "\n" + stdout))
        }
        let status = object["status"] as? String
        let error = (object["error"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
        let errorMessage = error.flatMap { $0.isEmpty ? nil : $0 } ?? AIService.firstCLIErrorLine(stderr)
        if status == "ERROR" {
            throw Failure.cliError(errorMessage)
        }
        let response = (object["response"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        if response.isEmpty, let denied = object["denied_actions"] as? [Any], !denied.isEmpty {
            throw Failure.deniedTool
        }
        guard exitCode == 0 else {
            throw Failure.cliError(errorMessage)
        }
        guard !response.isEmpty else { throw Failure.emptyResponse }
        guard status == "SUCCESS" else {
            throw Failure.cliError("Antigravity returned an unexpected status: \(status ?? "missing").")
        }
        return response
    }
}
