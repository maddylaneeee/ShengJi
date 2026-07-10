import Foundation

final class ProcessBox: @unchecked Sendable {
    var process: Process?
}

enum ProcessRunner {
    static func run(
        executable: URL,
        arguments: [String],
        onOutput: @escaping @Sendable (String) -> Void
    ) async throws -> Int32 {
        let box = ProcessBox()
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                let process = Process()
                let pipe = Pipe()
                process.executableURL = executable
                process.arguments = arguments
                process.standardOutput = pipe
                process.standardError = pipe
                box.process = process

                let readability = pipe.fileHandleForReading
                readability.readabilityHandler = { handle in
                    let data = handle.availableData
                    guard !data.isEmpty, let text = String(data: data, encoding: .utf8) else { return }
                    onOutput(text.trimmingCharacters(in: .newlines))
                }

                process.terminationHandler = { terminated in
                    readability.readabilityHandler = nil
                    continuation.resume(returning: terminated.terminationStatus)
                }

                do {
                    onOutput("$ \(executable.lastPathComponent) \(arguments.map(shellQuote).joined(separator: " "))")
                    try process.run()
                } catch {
                    readability.readabilityHandler = nil
                    continuation.resume(throwing: error)
                }
            }
        } onCancel: {
            box.process?.terminate()
        }
    }

    private static func shellQuote(_ value: String) -> String {
        if value.rangeOfCharacter(from: CharacterSet.whitespacesAndNewlines) == nil {
            return value
        }
        return "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }
}
