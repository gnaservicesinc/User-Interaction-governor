import Darwin
import Foundation

private final class ProcessRendererHandle: RendererHandle, @unchecked Sendable {
    private let process: Process
    private let input: Pipe
    private let lock = NSLock()
    private var stopped = false

    init(process: Process, input: Pipe) {
        self.process = process
        self.input = input
    }

    func stop() {
        lock.lock()
        guard !stopped else { lock.unlock(); return }
        stopped = true
        lock.unlock()
        try? input.fileHandleForWriting.close()
        guard process.isRunning else { return }
        process.terminate()
        let deadline = Date().addingTimeInterval(2)
        while process.isRunning && Date() < deadline { usleep(20_000) }
        if process.isRunning { kill(process.processIdentifier, SIGKILL) }
    }
}

public final class ProcessRendererSupervisor: RendererSupervisor, @unchecked Sendable {
    private let executable: URL

    public init(executable: URL) { self.executable = executable }

    public convenience init() throws {
        guard let executable = siblingExecutable(named: "uig-renderer") else {
            throw StructuredError("BACKEND_UNAVAILABLE", "cannot find uig-renderer next to uigd")
        }
        self.init(executable: executable)
    }

    public func launch(
        request: RendererRequest,
        event: @escaping @Sendable (RendererEvent) -> Void,
        terminated: @escaping @Sendable (Int32) -> Void
    ) throws -> RendererHandle {
        let process = Process()
        let input = Pipe()
        let output = Pipe()
        process.executableURL = executable
        process.arguments = []
        process.standardInput = input
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        var environment: [String: String] = ["PATH": "/usr/bin:/bin:/usr/sbin:/sbin"]
        let source = ProcessInfo.processInfo.environment
        for name in ["HOME", "USER", "LOGNAME", "TMPDIR", "SECURITYSESSIONID"] {
            if let value = source[name] { environment[name] = value }
        }
        process.environment = environment

        let readerQueue = DispatchQueue(label: "com.gnaservices.uig.renderer-reader.\(request.uuid)")
        readerQueue.async {
            var buffer = Data()
            while true {
                let chunk = output.fileHandleForReading.availableData
                if chunk.isEmpty { break }
                buffer.append(chunk)
                while let newline = buffer.firstIndex(of: 0x0A) {
                    let line = buffer[..<newline]
                    buffer.removeSubrange(...newline)
                    if let decoded = try? governorJSONDecoder().decode(RendererEvent.self, from: Data(line)) { event(decoded) }
                }
            }
        }
        process.terminationHandler = { process in
            readerQueue.async { terminated(process.terminationStatus) }
        }
        do { try process.run() }
        catch { throw StructuredError("BACKEND_UNAVAILABLE", "cannot launch renderer: \(error.localizedDescription)") }
        do {
            var data = try governorJSONEncoder().encode(request)
            data.append(0x0A)
            try input.fileHandleForWriting.write(contentsOf: data)
        } catch {
            process.terminate()
            throw StructuredError("IO_ERROR", "cannot initialize renderer")
        }
        return ProcessRendererHandle(process: process, input: input)
    }
}
