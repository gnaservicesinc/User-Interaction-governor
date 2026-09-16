import Foundation

public struct CapturedProcessResult: Sendable {
    public let status: Int32
    public let output: Data
    public let error: Data
}

/// Drain both streams while the child runs so neither pipe can block its exit.
public enum ProcessCapture {
    public static func run(_ executable: URL, arguments: [String]) throws -> CapturedProcessResult {
        let process = Process()
        let output = Pipe()
        let error = Pipe()
        process.executableURL = executable
        process.arguments = arguments
        process.standardOutput = output
        process.standardError = error
        try process.run()
        let outputReader = StreamReader(output.fileHandleForReading)
        let errorReader = StreamReader(error.fileHandleForReading)
        outputReader.start()
        errorReader.start()
        process.waitUntilExit()
        return CapturedProcessResult(status: process.terminationStatus,
                                     output: outputReader.result(), error: errorReader.result())
    }
}

private final class StreamReader: @unchecked Sendable {
    private let handle: FileHandle
    private let completed = DispatchSemaphore(value: 0)
    private var data = Data()

    init(_ handle: FileHandle) { self.handle = handle }

    func start() {
        DispatchQueue.global(qos: .userInitiated).async {
            self.data = self.handle.readDataToEndOfFile()
            self.completed.signal()
        }
    }

    func result() -> Data {
        completed.wait()
        return data
    }
}
