import Darwin
import Foundation
import GovernorCore

private struct ChildResult {
    var status: Int32
    var output: Data
    var error: Data
}

private let wrapperLock = NSLock()
private var wrapperUUID: String?
private var wrapperUIG: URL?
private var signalSources: [DispatchSourceSignal] = []

private func run(_ executable: URL, _ arguments: [String]) -> ChildResult {
    let process = Process()
    let output = Pipe()
    let error = Pipe()
    process.executableURL = executable
    process.arguments = arguments
    process.standardOutput = output
    process.standardError = error
    do { try process.run() }
    catch { return ChildResult(status: 5, output: Data(), error: Data("cannot launch uig: \(error.localizedDescription)\n".utf8)) }
    process.waitUntilExit()
    return ChildResult(status: process.terminationStatus, output: output.fileHandleForReading.readDataToEndOfFile(), error: error.fileHandleForReading.readDataToEndOfFile())
}

private func cleanup() -> Int32 {
    wrapperLock.lock()
    let uuid = wrapperUUID
    wrapperUUID = nil
    let executable = wrapperUIG
    wrapperLock.unlock()
    guard let uuid, let executable else { return 0 }
    return run(executable, ["--end", "--uuid", uuid]).status
}

private func installSignalCleanup() {
    for signalNumber in [SIGINT, SIGTERM, SIGHUP] {
        signal(signalNumber, SIG_IGN)
        let source = DispatchSource.makeSignalSource(signal: signalNumber, queue: .global(qos: .userInitiated))
        source.setEventHandler {
            _ = cleanup()
            exit(128 + signalNumber)
        }
        source.resume()
        signalSources.append(source)
    }
}

public func runWrapper(type: UIType) -> Never {
    let originalArguments = Array(CommandLine.arguments.dropFirst())
    if originalArguments == ["--version"] {
        print("ui-\(type.rawValue) \(governorVersion)")
        exit(0)
    }
    guard let executable = siblingExecutable(named: "uig") else {
        try? FileHandle.standardError.write(contentsOf: Data("wrapper: cannot find uig next to this executable\n".utf8))
        exit(5)
    }
    wrapperUIG = executable
    installSignalCleanup()
    var arguments = originalArguments
    if arguments.contains("--help") || arguments.contains("-h") {
        let positional = [.display, .choice, .entry, .confirm].contains(type) ? " MESSAGE" : ""
        print("Usage: ui-\(type.rawValue)\(positional) [uig creation options]\nCreates, presents, prints a JSON result, and cleans up one interaction.")
        exit(0)
    }
    var requestJSON = true
    if type == .display, let index = arguments.firstIndex(of: "--json") { requestJSON = true; arguments.remove(at: index) }
    else if type == .display { requestJSON = false }
    var creation = ["--new", "--ui-type", type.rawValue]
    if [.display, .choice, .entry, .confirm].contains(type) {
        guard let first = arguments.first, !first.hasPrefix("-") else {
            try? FileHandle.standardError.write(contentsOf: Data("ui-\(type.rawValue): a message is required\n".utf8))
            exit(2)
        }
        creation += ["--message", first]
        arguments.removeFirst()
    }
    var triggerOptions: [String] = []
    var index = 0
    while index < arguments.count {
        let value = arguments[index]
        if value == "--timeout" || value == "--start-timeout" {
            guard index + 1 < arguments.count else { exit(2) }
            triggerOptions += [value, arguments[index + 1]]
            arguments.removeSubrange(index...index + 1)
        } else if value.hasPrefix("--timeout=") || value.hasPrefix("--start-timeout=") {
            triggerOptions.append(value)
            arguments.remove(at: index)
        } else { index += 1 }
    }
    creation += arguments
    let created = run(executable, creation)
    guard created.status == 0, let uuid = String(data: created.output, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines), !uuid.isEmpty else {
        try? FileHandle.standardError.write(contentsOf: created.error)
        exit(created.status == 0 ? 5 : created.status)
    }
    wrapperLock.lock(); wrapperUUID = uuid; wrapperLock.unlock()
    var primary = run(executable, ["--trigger", "--uuid", uuid, "--wait"] + triggerOptions)
    if primary.status == 0, requestJSON {
        primary = run(executable, ["--dump", "--uuid", uuid])
        if primary.status == 0 { try? FileHandle.standardOutput.write(contentsOf: primary.output) }
    }
    if primary.status != 0 { try? FileHandle.standardError.write(contentsOf: primary.error) }
    let cleanupStatus = cleanup()
    exit(primary.status != 0 ? primary.status : cleanupStatus)
}
