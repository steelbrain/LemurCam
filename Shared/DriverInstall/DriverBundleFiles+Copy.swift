import Darwin
import Foundation

extension DriverBundleFiles {
    /// Copy the bundle directory at `sourcePath` to `name` inside `parent`. Only
    /// directories and regular files are accepted (a symlink or special file anywhere
    /// fails the copy); every created entry is new, owned by `owner`, mode 0755 (dirs,
    /// executables) or 0644, with no ACL. Data is copied, never cloned or linked, so
    /// nothing done to the source afterwards can reach the copy, and none of the
    /// source's owner, ACLs, or flags carry over (as root, `FileManager.copyItem`
    /// keeps the source owner, which is how the installed driver ended up
    /// user-writable).
    static func copyTree(from sourcePath: String, to parent: Int32, name: String, owner: Owner) throws {
        let source = try openDirectory(sourcePath)
        defer { close(source) }
        var job = CopyJob(owner: owner)
        let entry = Entry(name)
        try check(mkdirat(parent, entry.bytes, 0o700), "create \(name)")
        let destination = try openDirectory(at: parent, entry)
        defer { close(destination) }
        try job.copyContents(of: source, into: destination, path: name, depth: 0)
        try finalize(destination, mode: 0o755, owner: owner, path: name)
    }

    /// Owner, mode, and an empty ACL on a newly created entry (an inheritable ACL on
    /// the parent directory would otherwise be applied to it).
    static func finalize(_ descriptor: Int32, mode: mode_t, owner: Owner, path: String) throws {
        try check(fchown(descriptor, owner.uid, owner.gid), "chown \(path)")
        try check(fchmod(descriptor, mode), "chmod \(path)")
        guard let empty = acl_init(0) else { throw failure("clear ACL on \(path)") }
        defer { acl_free(UnsafeMutableRawPointer(empty)) }
        if acl_set_fd_np(descriptor, empty, ACL_TYPE_EXTENDED) != 0, errno != ENOTSUP {
            throw failure("clear ACL on \(path)")
        }
    }
}

/// One copy in progress: the owner to apply and the running entry/byte budget.
private struct CopyJob {
    typealias Files = DriverBundleFiles

    let owner: Files.Owner
    var entries = 0
    var bytes = 0

    init(owner: Files.Owner) {
        self.owner = owner
    }

    mutating func copyContents(of source: Int32, into destination: Int32, path: String, depth: Int) throws {
        guard depth < Files.Limits.maxDepth else {
            throw Files.Failure(description: "\(path): nested too deeply")
        }
        for entry in try Files.entries(of: source) {
            try addEntry()
            let entryPath = path + "/" + entry.display
            guard let info = try Files.status(at: source, entry) else {
                throw Files.Failure(description: "\(entryPath): disappeared while copying")
            }
            if Files.isDirectory(info) {
                try copyDirectory(entry, from: source, to: destination, path: entryPath, depth: depth)
            } else if Files.isRegularFile(info) {
                try copyFile(entry, from: source, to: destination, path: entryPath)
            } else if info.st_mode & Files.fileType == mode_t(S_IFLNK) {
                throw Files.Failure(description: "\(entryPath): symbolic links are not allowed in the driver bundle")
            } else {
                throw Files.Failure(description: "\(entryPath): unsupported file type")
            }
        }
    }

    private mutating func copyDirectory(
        _ entry: Files.Entry, from source: Int32, to destination: Int32, path: String, depth: Int
    ) throws {
        try Files.check(mkdirat(destination, entry.bytes, 0o700), "create \(path)")
        let childSource = try Files.openDirectory(at: source, entry)
        defer { close(childSource) }
        let childDestination = try Files.openDirectory(at: destination, entry)
        defer { close(childDestination) }
        try copyContents(of: childSource, into: childDestination, path: path, depth: depth + 1)
        try Files.finalize(childDestination, mode: 0o755, owner: owner, path: path)
    }

    private mutating func copyFile(
        _ entry: Files.Entry, from source: Int32, to destination: Int32, path: String
    ) throws {
        let input = try Files.check(openat(source, entry.bytes, Files.readFlags), "open \(path)")
        defer { close(input) }
        var info = stat()
        try Files.check(fstat(input, &info), "stat \(path)")
        guard Files.isRegularFile(info) else {
            throw Files.Failure(description: "\(path): changed type while copying")
        }
        let output = try Files.check(
            openat(destination, entry.bytes, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600),
            "create \(path)"
        )
        defer { close(output) }
        try copyBytes(from: input, to: output, path: path)
        let executable = info.st_mode & 0o111 != 0
        try Files.finalize(output, mode: executable ? 0o755 : 0o644, owner: owner, path: path)
    }

    private mutating func copyBytes(from input: Int32, to output: Int32, path: String) throws {
        var buffer = [UInt8](repeating: 0, count: 64 << 10)
        while true {
            let count = buffer.withUnsafeMutableBytes { read(input, $0.baseAddress, $0.count) }
            if count == 0 { return }
            if count < 0 {
                if errno == EINTR { continue }
                throw Files.failure("read \(path)")
            }
            try addBytes(count)
            try writeAll(buffer, count: count, to: output, path: path)
        }
    }

    private func writeAll(_ buffer: [UInt8], count: Int, to output: Int32, path: String) throws {
        var offset = 0
        while offset < count {
            let written = buffer.withUnsafeBytes { raw -> Int in
                guard let base = raw.baseAddress else { return -1 }
                return write(output, base + offset, count - offset)
            }
            if written < 0 {
                if errno == EINTR { continue }
                throw Files.failure("write \(path)")
            }
            offset += written
        }
    }

    private mutating func addEntry() throws {
        entries += 1
        guard entries <= Files.Limits.maxEntries else {
            throw Files.Failure(description: "driver bundle has more than \(Files.Limits.maxEntries) entries")
        }
    }

    private mutating func addBytes(_ count: Int) throws {
        bytes += count
        guard bytes <= Files.Limits.maxTotalBytes else {
            throw Files.Failure(description: "driver bundle is larger than \(Files.Limits.maxTotalBytes) bytes")
        }
    }
}
