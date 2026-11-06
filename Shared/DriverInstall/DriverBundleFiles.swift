import Darwin
import Foundation

/// File-descriptor-relative filesystem operations the privileged helper runs on
/// driver bundles. Every path component below an already-open directory is opened
/// with `O_NOFOLLOW` relative to that directory, so a user who controls part of a
/// tree (the app bundle the driver is copied from, or a driver an older helper
/// installed with the user as owner) cannot redirect a root copy, chown, read, or
/// delete through a symlink or a swapped directory.
///
/// Compiled into the helper, which runs these as root, and into the app, which runs
/// only the read-only audit of the installed copy (as the user), and whose unit tests
/// exercise all of them on temporary directories as the current user.
/// Copy, audit, and removal live in the `+Copy` and `+Audit` files.
internal enum DriverBundleFiles {
    /// Owner every copied entry is given (root:wheel in the helper).
    struct Owner: Equatable {
        let uid: uid_t
        let gid: gid_t

        static let root = Self(uid: 0, gid: 0)
    }

    struct Failure: Error, CustomStringConvertible {
        let description: String
    }

    /// Bounds on the work an attacker-shaped source tree can cause.
    enum Limits {
        static let maxDepth = 16
        static let maxEntries = 4096
        static let maxTotalBytes = 64 << 20
        static let maxPlistBytes = 1 << 20
    }

    /// A directory entry name kept as raw bytes, so names that are not valid UTF-8
    /// can still be opened or removed; `display` is only for messages.
    struct Entry {
        let bytes: [CChar]
        let display: String

        init(_ name: String) {
            bytes = Array(name.utf8CString)
            display = name
        }

        init(raw: [CChar]) {
            bytes = raw + [0]
            display = String(bytes: raw.map { UInt8(bitPattern: $0) }, encoding: .utf8) ?? "<non-UTF-8 name>"
        }
    }

    static let directoryFlags = O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC
    static let readFlags = O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC
    static let fileType = mode_t(S_IFMT)

    // MARK: - Opening and listing

    /// Open a directory by absolute path. Only the last component is protected by
    /// `O_NOFOLLOW`; callers pass paths whose parents are not user-controlled, or
    /// whose contents are verified afterwards (the code signature of a copy).
    static func openDirectory(_ path: String) throws -> Int32 {
        try check(open(path, directoryFlags), "open \((path as NSString).lastPathComponent)")
    }

    static func openDirectory(at parent: Int32, _ entry: Entry) throws -> Int32 {
        try check(openat(parent, entry.bytes, directoryFlags), "open \(entry.display)")
    }

    /// `fstatat` without following a symlink; nil if the entry does not exist.
    static func status(at parent: Int32, _ entry: Entry) throws -> stat? {
        var info = stat()
        guard fstatat(parent, entry.bytes, &info, AT_SYMLINK_NOFOLLOW) == 0 else {
            if errno == ENOENT { return nil }
            throw failure("stat \(entry.display)")
        }
        return info
    }

    static func isDirectory(_ info: stat) -> Bool {
        info.st_mode & fileType == mode_t(S_IFDIR)
    }

    static func isRegularFile(_ info: stat) -> Bool {
        info.st_mode & fileType == mode_t(S_IFREG)
    }

    /// Names in a directory, excluding `.` and `..`.
    static func entries(of directory: Int32) throws -> [Entry] {
        let duplicate = try check(dup(directory), "dup")
        guard let stream = fdopendir(duplicate) else {
            let error = failure("list directory")
            close(duplicate)
            throw error
        }
        defer { closedir(stream) }
        rewinddir(stream) // the duplicate shares the original descriptor's offset
        var names: [Entry] = []
        while true {
            errno = 0
            guard let item = readdir(stream) else {
                if errno != 0 { throw failure("list directory") }
                return names
            }
            let raw = withUnsafeBytes(of: item.pointee.d_name) { buffer in
                Array(buffer.prefix(Int(item.pointee.d_namlen))).map { CChar(bitPattern: $0) }
            }
            if raw == [46] || raw == [46, 46] { continue } // "." and ".."
            names.append(Entry(raw: raw))
            guard names.count <= Limits.maxEntries else {
                throw Failure(description: "directory has more than \(Limits.maxEntries) entries")
            }
        }
    }

    // MARK: - Read

    /// Contents of the regular file at `components` below `parent`, opening every
    /// component without following symlinks; nil if any part is missing, a symlink,
    /// not a regular file, or larger than `maxBytes`.
    static func readFile(at parent: Int32, components: [String], maxBytes: Int) -> Data? {
        guard let file = openFile(at: parent, components: components) else { return nil }
        defer { close(file) }
        var info = stat()
        guard fstat(file, &info) == 0, isRegularFile(info), info.st_size >= 0, info.st_size <= maxBytes else {
            return nil
        }
        var data = Data(count: Int(info.st_size))
        let complete = data.withUnsafeMutableBytes { readFully(file, into: $0) }
        return complete ? data : nil
    }

    /// `CFBundleVersion` of the bundle `name` inside `parent`, read without following
    /// symlinks; nil if it is missing or unreadable.
    static func bundleVersion(at parent: Int32, bundle name: String) -> String? {
        guard let data = readFile(
            at: parent, components: [name, "Contents", "Info.plist"], maxBytes: Limits.maxPlistBytes
        ), let plist = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any]
        else { return nil }
        return plist["CFBundleVersion"] as? String
    }

    private static func openFile(at parent: Int32, components: [String]) -> Int32? {
        guard let last = components.last else { return nil }
        var directory = dup(parent)
        guard directory >= 0 else { return nil }
        defer { close(directory) }
        for component in components.dropLast() {
            let next = openat(directory, component, directoryFlags)
            guard next >= 0 else { return nil }
            close(directory)
            directory = next
        }
        let file = openat(directory, last, readFlags)
        return file >= 0 ? file : nil
    }

    private static func readFully(_ file: Int32, into buffer: UnsafeMutableRawBufferPointer) -> Bool {
        guard let base = buffer.baseAddress else { return buffer.isEmpty }
        var offset = 0
        while offset < buffer.count {
            let count = read(file, base + offset, buffer.count - offset)
            if count < 0, errno == EINTR { continue }
            guard count > 0 else { return false }
            offset += count
        }
        return true
    }

    // MARK: - Errors

    @discardableResult
    static func check(_ result: Int32, _ action: @autoclosure () -> String) throws -> Int32 {
        guard result >= 0 else { throw failure(action()) }
        return result
    }

    /// A failure for the current `errno`, captured before `action` (which may
    /// allocate) is evaluated. Call immediately after the failing call.
    static func failure(_ action: @autoclosure () -> String) -> Failure {
        let code = errno
        return Failure(description: "\(action()): \(String(cString: strerror(code)))")
    }
}
