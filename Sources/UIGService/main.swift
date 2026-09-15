import Darwin
import Foundation
import GovernorCore

private func serviceError(_ message: String) {
    try? FileHandle.standardError.write(contentsOf: Data("uigd: \(message)\n".utf8))
}

let arguments = Set(CommandLine.arguments.dropFirst())
guard arguments.isSubset(of: ["--daemon", "--foreground"]) else {
    serviceError("usage: uigd [--daemon|--foreground]")
    exit(2)
}

if arguments.contains("--daemon") { _ = setsid() }

let runtime = runtimePathsFromEnvironment()
do { try runtime.prepare() }
catch { serviceError("cannot prepare runtime directory"); exit(1) }

let lockDescriptor = open(runtime.lock.path, O_RDWR | O_CREAT | O_CLOEXEC, 0o600)
guard lockDescriptor >= 0 else { serviceError("cannot open instance lock"); exit(1) }
guard flock(lockDescriptor, LOCK_EX | LOCK_NB) == 0 else { close(lockDescriptor); exit(0) }

let listener: Int32
let engine: GovernorEngine
do {
    let store = try SQLiteStore(path: runtime.database.path)
    let supervisor = try ProcessRendererSupervisor()
    engine = try GovernorEngine(store: store, paths: runtime, supervisor: supervisor)
    listener = try UnixSocket.listen(path: runtime.socket.path)
} catch let error as StructuredError {
    serviceError(error.message)
    close(lockDescriptor)
    exit(error.exitCode)
} catch {
    serviceError(error.localizedDescription)
    close(lockDescriptor)
    exit(1)
}

let timer = DispatchSource.makeTimerSource(queue: DispatchQueue.global(qos: .utility))
timer.schedule(deadline: .now(), repeating: .milliseconds(200), leeway: .milliseconds(50))
timer.setEventHandler { engine.scanSignalsAndExpiry() }
timer.resume()

while true {
    let connection = accept(listener, nil, nil)
    if connection < 0 {
        if errno == EINTR { continue }
        break
    }
    DispatchQueue.global(qos: .userInitiated).async {
        defer { close(connection) }
        guard UnixSocket.peerIsCurrentUser(connection) else { return }
        do {
            let request = try IPCWire.receive(IPCRequest.self, descriptor: connection)
            let response = engine.handle(request)
            try IPCWire.send(response, descriptor: connection)
        } catch let error as StructuredError {
            try? IPCWire.send(IPCResponse.failure(error), descriptor: connection)
        } catch {
            try? IPCWire.send(IPCResponse.failure(StructuredError("IO_ERROR", "service request failed")), descriptor: connection)
        }
    }
}

timer.cancel()
close(listener)
unlink(runtime.socket.path)
close(lockDescriptor)
