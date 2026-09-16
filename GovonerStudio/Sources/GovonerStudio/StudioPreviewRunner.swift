import Foundation
import GovonerStudioCore

enum StudioPreviewRunner {
    static func run(_ project: StudioProject) async throws -> String {
        try await Task.detached(priority: .userInitiated) {
            let executable = try locateUIG()
            let steps = project.steps
            guard let first = steps.first else { throw PreviewError("Add an interaction before previewing.") }

            let create = try process(executable, ["--new"] + first.commandArguments())
            let uuid = create.trimmingCharacters(in: .whitespacesAndNewlines)
            guard UUID(uuidString: uuid) != nil else {
                throw PreviewError("The Govoner returned an invalid preview UUID.")
            }

            do {
                for step in steps.dropFirst() {
                    _ = try process(executable, ["--stack", "--uuid", uuid] + step.commandArguments())
                }
                _ = try process(executable, ["--trigger", "--uuid", uuid])
                return uuid
            } catch {
                _ = try? process(executable, ["--end", "--uuid", uuid])
                throw error
            }
        }.value
    }

    private static func process(_ executable: URL, _ arguments: [String]) throws -> String {
        let process = Process()
        let stdout = Pipe()
        let stderr = Pipe()
        process.executableURL = executable
        process.arguments = arguments
        process.standardOutput = stdout
        process.standardError = stderr
        do {
            try process.run()
        } catch {
            throw PreviewError("Could not launch The Govoner: \(error.localizedDescription)")
        }
        process.waitUntilExit()
        let outputData = stdout.fileHandleForReading.readDataToEndOfFile()
        let errorData = stderr.fileHandleForReading.readDataToEndOfFile()
        guard process.terminationStatus == 0 else {
            let message = String(data: errorData, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines)
            throw PreviewError(message?.isEmpty == false ? message! : "The Govoner exited with status \(process.terminationStatus).")
        }
        return String(data: outputData, encoding: .utf8) ?? ""
    }

    private static func locateUIG() throws -> URL {
        let manager = FileManager.default
        var candidates: [URL] = []
        if let executable = Bundle.main.executableURL {
            let contents = executable.deletingLastPathComponent().deletingLastPathComponent()
            candidates.append(contents.appendingPathComponent("Components/bin/uig"))
            candidates.append(contents.appendingPathComponent("Helpers/uig"))
            candidates.append(executable.deletingLastPathComponent().appendingPathComponent("uig"))
        }
        candidates.append(URL(fileURLWithPath: "/opt/homebrew/bin/uig"))
        candidates.append(URL(fileURLWithPath: "/usr/local/bin/uig"))

        if let path = ProcessInfo.processInfo.environment["PATH"] {
            candidates.append(contentsOf: path.split(separator: ":").map {
                URL(fileURLWithPath: String($0), isDirectory: true).appendingPathComponent("uig")
            })
        }
        if let match = candidates.first(where: { manager.isExecutableFile(atPath: $0.path) }) {
            return match
        }
        throw PreviewError("Could not find uig. Build the complete package or install The Govoner before previewing.")
    }
}

private struct PreviewError: LocalizedError {
    let message: String
    init(_ message: String) { self.message = message }
    var errorDescription: String? { message }
}
