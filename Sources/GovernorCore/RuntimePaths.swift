import Darwin
import Foundation

public struct RuntimePaths: Sendable {
    public let root: URL
    public var database: URL { root.appendingPathComponent("governor.sqlite3") }
    public var socket: URL { root.appendingPathComponent("uigd.sock") }
    public var lock: URL { root.appendingPathComponent("uigd.lock") }
    public var interactions: URL { root.appendingPathComponent("interactions", isDirectory: true) }

    public init(root: URL? = nil) {
        if let root {
            self.root = root
        } else {
            self.root = FileManager.default.homeDirectoryForCurrentUser
                .appendingPathComponent("Library/Application Support/UserInteractionGovernor", isDirectory: true)
        }
    }

    public func prepare() throws {
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        try FileManager.default.createDirectory(at: interactions, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        guard chmod(root.path, 0o700) == 0, chmod(interactions.path, 0o700) == 0 else {
            throw StructuredError("IO_ERROR", "cannot secure governor data directory")
        }
    }

    public func directory(for uuid: String) -> URL {
        interactions.appendingPathComponent(uuid, isDirectory: true)
    }
}

public func currentSessionID() -> String {
    let environment = ProcessInfo.processInfo.environment
    if let session = environment["SECURITYSESSIONID"], !session.isEmpty { return session }
    return "uid-\(getuid())-console-\(consoleOwnerUID())"
}

private func consoleOwnerUID() -> uid_t {
    var info = stat()
    return stat("/dev/console", &info) == 0 ? info.st_uid : getuid()
}

public func siblingExecutable(named name: String) -> URL? {
    guard let executable = Bundle.main.executableURL else { return nil }
    let candidate = executable.deletingLastPathComponent().appendingPathComponent(name)
    return FileManager.default.isExecutableFile(atPath: candidate.path) ? candidate : nil
}
