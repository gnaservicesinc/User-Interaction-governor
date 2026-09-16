import Darwin
import Foundation

public struct FileIdentity: Codable, Sendable, Equatable {
    public var device: UInt64
    public var inode: UInt64
}

public enum AtomicFiles {
    public static func identity(at path: String) -> FileIdentity? {
        var info = stat()
        guard lstat(path, &info) == 0 else { return nil }
        return FileIdentity(device: UInt64(info.st_dev), inode: UInt64(info.st_ino))
    }

    public static func isRegularFileWithoutFollowingSymlinks(_ path: String) -> Bool {
        var info = stat()
        guard lstat(path, &info) == 0 else { return false }
        return (info.st_mode & S_IFMT) == S_IFREG
    }

    public static func write(_ data: Data, to path: String, allowReplacing identity: FileIdentity? = nil, requirePrivateParent: Bool = true) throws -> FileIdentity {
        let manager = FileManager.default
        let destination = URL(fileURLWithPath: path)
        let parent = destination.deletingLastPathComponent()
        if requirePrivateParent { try validatePrivateParent(of: path) }
        guard manager.fileExists(atPath: parent.path) else {
            throw StructuredError("IO_ERROR", "parent directory does not exist: \(parent.path)")
        }
        let existing = self.identity(at: path)
        if let existing, existing != identity {
            throw StructuredError("PATH_CONFLICT", "refusing to replace an unrelated file: \(path)")
        }
        let temporary = parent.appendingPathComponent(".uig-\(UUID().uuidString).tmp")
        let fd = open(temporary.path, O_WRONLY | O_CREAT | O_EXCL | O_CLOEXEC, 0o600)
        guard fd >= 0 else { throw StructuredError("IO_ERROR", "cannot create output file: \(path)") }
        var writeError: StructuredError?
        data.withUnsafeBytes { raw in
            var offset = 0
            while offset < raw.count {
                let count = Darwin.write(fd, raw.baseAddress!.advanced(by: offset), raw.count - offset)
                if count < 0 && errno == EINTR { continue }
                if count <= 0 {
                    writeError = StructuredError("IO_ERROR", "cannot write output file: \(path)")
                    break
                }
                offset += count
            }
        }
        if writeError == nil && fsync(fd) != 0 { writeError = StructuredError("IO_ERROR", "cannot sync output file: \(path)") }
        close(fd)
        if let writeError {
            unlink(temporary.path)
            throw writeError
        }
        if let identity, existing != nil {
            guard renameatx_np(AT_FDCWD, temporary.path, AT_FDCWD, path, UInt32(RENAME_SWAP)) == 0 else {
                unlink(temporary.path)
                throw StructuredError("IO_ERROR", "cannot atomically replace output file: \(path)")
            }
            guard self.identity(at: temporary.path) == identity else {
                _ = renameatx_np(AT_FDCWD, temporary.path, AT_FDCWD, path, UInt32(RENAME_SWAP))
                unlink(temporary.path)
                throw StructuredError("PATH_CONFLICT", "output file was replaced concurrently: \(path)")
            }
            unlink(temporary.path)
        } else if renameatx_np(AT_FDCWD, temporary.path, AT_FDCWD, path, UInt32(RENAME_EXCL)) != 0 {
            let publishError = errno
            unlink(temporary.path)
            if publishError == EEXIST { throw StructuredError("PATH_CONFLICT", "output file appeared concurrently: \(path)") }
            throw StructuredError("IO_ERROR", "cannot publish output file: \(path)")
        }
        let directoryFD = open(parent.path, O_RDONLY | O_CLOEXEC)
        if directoryFD >= 0 { _ = fsync(directoryFD); close(directoryFD) }
        guard let result = self.identity(at: path) else { throw StructuredError("IO_ERROR", "published file disappeared: \(path)") }
        return result
    }

    public static func removeIfOwned(_ path: String, identity: FileIdentity?) throws {
        guard let existing = self.identity(at: path) else { return }
        try validatePrivateParent(of: path)
        guard let identity, existing == identity else {
            throw StructuredError("PATH_CONFLICT", "refusing to remove a replaced file: \(path)")
        }
        guard unlink(path) == 0 || errno == ENOENT else {
            throw StructuredError("IO_ERROR", "cannot remove governor output: \(path)")
        }
    }
}

public func safeProtocolSignalExists(_ path: String) -> Bool {
    guard (try? validatePrivateParent(of: path)) != nil else { return false }
    return AtomicFiles.isRegularFileWithoutFollowingSymlinks(path)
}

public func absolutePath(_ value: String, relativeTo workingDirectory: String) -> String {
    let url = value.hasPrefix("/")
        ? URL(fileURLWithPath: value)
        : URL(fileURLWithPath: workingDirectory, isDirectory: true).appendingPathComponent(value)
    let standardized = url.standardizedFileURL
    let parent = standardized.deletingLastPathComponent().resolvingSymlinksInPath()
    return parent.appendingPathComponent(standardized.lastPathComponent).path
}

public func pathReservationKey(_ path: String) -> String {
    path.precomposedStringWithCanonicalMapping.lowercased()
}

public func validatePrivateParent(of path: String, ownerUID: uid_t = getuid()) throws {
    let parent = URL(fileURLWithPath: path).deletingLastPathComponent().path
    var info = stat()
    guard lstat(parent, &info) == 0, (info.st_mode & S_IFMT) == S_IFDIR else {
        throw StructuredError("INVALID_ARGUMENT", "protocol parent is not an existing directory: \(parent)")
    }
    guard info.st_uid == ownerUID else {
        throw StructuredError("INVALID_ARGUMENT", "protocol parent is not owned by the current user: \(parent)")
    }
    guard (info.st_mode & 0o077) == 0 else {
        throw StructuredError("INVALID_ARGUMENT", "protocol parent must not be accessible by group or other users: \(parent)")
    }
    var filesystem = statfs()
    guard statfs(parent, &filesystem) == 0 else { throw StructuredError("IO_ERROR", "cannot inspect protocol filesystem") }
    let localFlag = UInt32(MNT_LOCAL)
    guard UInt32(filesystem.f_flags) & localFlag != 0 else {
        throw StructuredError("INVALID_ARGUMENT", "network filesystems are not supported for protocol paths")
    }
}
