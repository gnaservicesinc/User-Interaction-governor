import Darwin
import Foundation

private let maximumIPCMessage = 2 * 1_048_576

public func runtimePathsFromEnvironment() -> RuntimePaths {
    if let value = ProcessInfo.processInfo.environment["UIG_RUNTIME_DIRECTORY"], !value.isEmpty {
        return RuntimePaths(root: URL(fileURLWithPath: value, isDirectory: true))
    }
    return RuntimePaths()
}

public enum IPCWire {
    public static func send<T: Encodable>(_ value: T, descriptor: Int32) throws {
        let payload = try governorJSONEncoder().encode(value)
        guard payload.count <= maximumIPCMessage else { throw StructuredError("INVALID_ARGUMENT", "IPC message is too large") }
        var length = UInt32(payload.count).bigEndian
        try withUnsafeBytes(of: &length) { try writeAll($0, descriptor: descriptor) }
        try payload.withUnsafeBytes { try writeAll($0, descriptor: descriptor) }
    }

    public static func receive<T: Decodable>(_ type: T.Type, descriptor: Int32) throws -> T {
        let header = try readExactly(4, descriptor: descriptor)
        let count = header.reduce(UInt32(0)) { ($0 << 8) | UInt32($1) }
        guard count <= maximumIPCMessage else { throw StructuredError("INVALID_ARGUMENT", "IPC message is too large") }
        let payload = try readExactly(Int(count), descriptor: descriptor)
        do { return try governorJSONDecoder().decode(type, from: payload) }
        catch { throw StructuredError("INVALID_ARGUMENT", "invalid IPC request") }
    }

    private static func writeAll(_ buffer: UnsafeRawBufferPointer, descriptor: Int32) throws {
        var offset = 0
        while offset < buffer.count {
            let written = Darwin.write(descriptor, buffer.baseAddress!.advanced(by: offset), buffer.count - offset)
            if written < 0 && errno == EINTR { continue }
            guard written > 0 else { throw StructuredError("IO_ERROR", "IPC connection closed while writing") }
            offset += written
        }
    }

    private static func readExactly(_ count: Int, descriptor: Int32) throws -> Data {
        var data = Data(count: count)
        var offset = 0
        while offset < count {
            let readCount = data.withUnsafeMutableBytes { raw in
                Darwin.read(descriptor, raw.baseAddress!.advanced(by: offset), count - offset)
            }
            if readCount < 0 && errno == EINTR { continue }
            guard readCount > 0 else { throw StructuredError("IO_ERROR", "IPC connection closed while reading") }
            offset += readCount
        }
        return data
    }
}

public final class IPCClient: @unchecked Sendable {
    public let paths: RuntimePaths

    public init(paths: RuntimePaths = runtimePathsFromEnvironment()) { self.paths = paths }

    public func send(_ request: IPCRequest, autostart: Bool = true) throws -> IPCResponse {
        let descriptor = try connect(autostart: autostart)
        defer { close(descriptor) }
        // Once sent, a request may already be committed. Never replay it after a lost reply.
        try IPCWire.send(request, descriptor: descriptor)
        return try IPCWire.receive(IPCResponse.self, descriptor: descriptor)
    }

    private func connect(autostart: Bool) throws -> Int32 {
        do { return try UnixSocket.connect(path: paths.socket.path) }
        catch {
            guard autostart else { throw error }
            try startService()
            var lastError: Error = error
            for delay in [20_000, 40_000, 80_000, 160_000, 300_000, 500_000, 800_000, 1_000_000] {
                usleep(useconds_t(delay))
                do { return try UnixSocket.connect(path: paths.socket.path) }
                catch { lastError = error }
            }
            throw lastError
        }
    }

    private func startService() throws {
        guard let service = siblingExecutable(named: "uigd") else {
            throw StructuredError("BACKEND_UNAVAILABLE", "cannot find uigd next to the uig executable")
        }
        let process = Process()
        process.executableURL = service
        process.arguments = ["--daemon"]
        var environment: [String: String] = ["PATH": "/usr/bin:/bin:/usr/sbin:/sbin"]
        let source = ProcessInfo.processInfo.environment
        for name in ["HOME", "USER", "LOGNAME", "TMPDIR", "SECURITYSESSIONID", "UIG_RUNTIME_DIRECTORY"] {
            if let value = source[name] { environment[name] = value }
        }
        process.environment = environment
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        do { try process.run() }
        catch { throw StructuredError("BACKEND_UNAVAILABLE", "cannot start uigd: \(error.localizedDescription)") }
    }
}

public enum UnixSocket {
    public static func connect(path: String) throws -> Int32 {
        let descriptor = socket(AF_UNIX, SOCK_STREAM, 0)
        guard descriptor >= 0 else { throw StructuredError("BACKEND_UNAVAILABLE", "cannot create IPC socket") }
        _ = fcntl(descriptor, F_SETFD, FD_CLOEXEC)
        var noPipe: Int32 = 1
        _ = setsockopt(descriptor, SOL_SOCKET, SO_NOSIGPIPE, &noPipe, socklen_t(MemoryLayout<Int32>.size))
        do {
            var address = try socketAddress(path: path)
            let result = withUnsafePointer(to: &address) {
                $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                    Darwin.connect(descriptor, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
                }
            }
            guard result == 0 else { throw StructuredError("BACKEND_UNAVAILABLE", "uigd is not available", retryable: true) }
            return descriptor
        } catch {
            close(descriptor)
            throw error
        }
    }

    public static func listen(path: String) throws -> Int32 {
        unlink(path)
        let descriptor = socket(AF_UNIX, SOCK_STREAM, 0)
        guard descriptor >= 0 else { throw StructuredError("IO_ERROR", "cannot create service socket") }
        _ = fcntl(descriptor, F_SETFD, FD_CLOEXEC)
        var noPipe: Int32 = 1
        _ = setsockopt(descriptor, SOL_SOCKET, SO_NOSIGPIPE, &noPipe, socklen_t(MemoryLayout<Int32>.size))
        do {
            var address = try socketAddress(path: path)
            let bound = withUnsafePointer(to: &address) {
                $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                    bind(descriptor, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
                }
            }
            guard bound == 0, chmod(path, 0o600) == 0, Darwin.listen(descriptor, 32) == 0 else {
                throw StructuredError("IO_ERROR", "cannot bind private service socket")
            }
            return descriptor
        } catch {
            close(descriptor)
            unlink(path)
            throw error
        }
    }

    public static func peerIsCurrentUser(_ descriptor: Int32) -> Bool {
        var uid: uid_t = 0
        var gid: gid_t = 0
        return getpeereid(descriptor, &uid, &gid) == 0 && uid == getuid()
    }

    private static func socketAddress(path: String) throws -> sockaddr_un {
        let bytes = Array(path.utf8)
        var address = sockaddr_un()
        let capacity = MemoryLayout.size(ofValue: address.sun_path)
        guard bytes.count < capacity else { throw StructuredError("IO_ERROR", "service socket path is too long") }
        address.sun_family = sa_family_t(AF_UNIX)
        address.sun_len = UInt8(MemoryLayout<sockaddr_un>.size)
        withUnsafeMutablePointer(to: &address.sun_path) { pointer in
            pointer.withMemoryRebound(to: CChar.self, capacity: capacity) { characters in
                for (index, byte) in bytes.enumerated() { characters[index] = CChar(bitPattern: byte) }
                characters[bytes.count] = 0
            }
        }
        return address
    }
}
