import Darwin
import Foundation

extension DriverBundleFiles {
    // MARK: - Audit

    /// Which copy of the driver an audit checks. It decides whether a file's other
    /// hard links count as a problem.
    enum AuditedCopy {
        /// The copy just made in the private staging directory (0700, owned by the
        /// owner), which nobody else can reach: a file there with more than one link
        /// is not the fresh file the copy wrote.
        case staged
        /// The copy in the plug-ins directory. Every user can read it, and macOS lets
        /// any user hard-link a file they can read, even one they do not own. That
        /// raises the file's link count but gives them no way to change it (owner and
        /// mode belong to the file, not to a link), so the link count is not checked:
        /// otherwise anyone could make a sealed copy look unsealed.
        case installed
    }

    /// Every reason the tree at `name` inside `parent` could be modified by anyone
    /// but `owner`: entries owned by someone else, writable by group or others,
    /// setuid/setgid/sticky bits, an ACL, a symlink, or a special file, plus, for the
    /// `.staged` copy, a hard-linked file. Empty means the tree is sealed to `owner`.
    /// With `limit`, stops after that many problems.
    static func audit(
        _ parent: Int32, name: String, owner: Owner, copy: AuditedCopy, limit: Int = .max
    ) -> [String] {
        var problems = Problems(limit: limit, rejectsHardLinks: copy == .staged)
        auditEntry(Entry(name), in: parent, path: name, depth: 0, owner: owner, problems: &problems)
        return problems.found
    }

    /// Whether the tree at `name` inside `parent` exists and is sealed to `owner`:
    /// `audit` reports nothing. Stops at the first problem, so a large tree someone
    /// else can write to is not walked in full.
    static func isSealed(_ parent: Int32, name: String, owner: Owner, copy: AuditedCopy) -> Bool {
        audit(parent, name: name, owner: owner, copy: copy, limit: 1).isEmpty
    }

    /// Problems found so far, up to `limit`, and whether a regular file with more
    /// than one link is one of them (see `AuditedCopy`).
    private struct Problems {
        let limit: Int
        let rejectsHardLinks: Bool
        var found: [String] = []

        var isFull: Bool { found.count >= limit }

        mutating func append(_ problem: String) {
            if !isFull { found.append(problem) }
        }

        static func += (problems: inout Self, more: [String]) {
            more.forEach { problems.append($0) }
        }
    }

    // Parameters mirror the recursion state; grouping them would only hide it.
    // swiftlint:disable:next function_parameter_count
    private static func auditEntry(
        _ entry: Entry, in parent: Int32, path: String, depth: Int, owner: Owner, problems: inout Problems
    ) {
        guard !problems.isFull else { return }
        guard let info = try? status(at: parent, entry) else {
            problems.append("\(path): missing or unreadable")
            return
        }
        guard isDirectory(info) || isRegularFile(info) else {
            let kind = info.st_mode & fileType == mode_t(S_IFLNK) ? "symbolic link" : "unsupported file type"
            problems.append("\(path): \(kind)")
            return
        }
        let descriptor = openat(parent, entry.bytes, isDirectory(info) ? directoryFlags : readFlags)
        guard descriptor >= 0 else {
            problems.append("\(path): cannot be opened")
            return
        }
        defer { close(descriptor) }
        var opened = stat()
        guard fstat(descriptor, &opened) == 0, opened.st_mode & fileType == info.st_mode & fileType else {
            problems.append("\(path): changed while auditing")
            return
        }
        problems += permissionProblems(
            opened, descriptor: descriptor, owner: owner, rejectsHardLinks: problems.rejectsHardLinks
        ).map { "\(path): \($0)" }
        guard isDirectory(opened) else { return }
        guard depth < Limits.maxDepth, let children = try? entries(of: descriptor) else {
            problems.append("\(path): cannot be listed")
            return
        }
        for child in children {
            auditEntry(
                child, in: descriptor, path: path + "/" + child.display, depth: depth + 1,
                owner: owner, problems: &problems
            )
        }
    }

    private static func permissionProblems(
        _ info: stat, descriptor: Int32, owner: Owner, rejectsHardLinks: Bool
    ) -> [String] {
        var problems: [String] = []
        if info.st_uid != owner.uid || info.st_gid != owner.gid {
            problems.append("owned by \(info.st_uid):\(info.st_gid)")
        }
        if info.st_mode & 0o022 != 0 { problems.append("writable by group or others") }
        if info.st_mode & 0o7000 != 0 { problems.append("has setuid, setgid, or sticky bits") }
        if rejectsHardLinks, isRegularFile(info), info.st_nlink != 1 { problems.append("hard-linked") }
        if hasACL(descriptor) { problems.append("has an access control list") }
        return problems
    }

    private static func hasACL(_ descriptor: Int32) -> Bool {
        guard let acl = acl_get_fd_np(descriptor, ACL_TYPE_EXTENDED) else { return false }
        defer { acl_free(UnsafeMutableRawPointer(acl)) }
        var first: acl_entry_t?
        return acl_get_entry(acl, ACL_FIRST_ENTRY.rawValue, &first) == 0
    }

    // MARK: - Remove

    /// Delete `name` inside `parent` and everything under it without following
    /// symlinks: a symlink is unlinked itself, and every directory is descended
    /// through a descriptor opened with `O_NOFOLLOW`, so deletion never leaves the
    /// tree even if entries are swapped while it runs. Missing is not an error.
    static func removeTree(at parent: Int32, name: String) throws {
        try removeEntry(Entry(name), in: parent, path: name, depth: 0)
    }

    private static func removeEntry(_ entry: Entry, in parent: Int32, path: String, depth: Int) throws {
        guard let info = try status(at: parent, entry) else { return }
        guard isDirectory(info) else {
            try unlink(entry, in: parent, path: path, flags: 0)
            return
        }
        guard depth < Limits.maxDepth else { throw Failure(description: "\(path): nested too deeply") }
        guard let directory = try openForRemoval(entry, in: parent, path: path) else { return }
        defer { close(directory) }
        // A few passes in case entries are added while we delete (a user-owned tree).
        for pass in 1...3 {
            for child in try entries(of: directory) {
                try removeEntry(child, in: directory, path: path + "/" + child.display, depth: depth + 1)
            }
            if unlinkat(parent, entry.bytes, AT_REMOVEDIR) == 0 || errno == ENOENT { return }
            if errno != ENOTEMPTY || pass == 3 { break }
        }
        try unlink(entry, in: parent, path: path, flags: AT_REMOVEDIR)
    }

    /// Open a directory about to be emptied. Returns nil when there is nothing more
    /// to do: it vanished, or it was swapped for a non-directory (then unlinked).
    private static func openForRemoval(_ entry: Entry, in parent: Int32, path: String) throws -> Int32? {
        let directory = openat(parent, entry.bytes, directoryFlags)
        if directory >= 0 { return directory }
        switch errno {
        case ENOENT:
            return nil
        case ENOTDIR, ELOOP:
            try unlink(entry, in: parent, path: path, flags: 0)
            return nil
        default:
            throw failure("open \(path)")
        }
    }

    /// `unlinkat`, retried once after clearing file flags (a user-immutable flag
    /// would otherwise make a user-owned tree undeletable, even for root).
    private static func unlink(_ entry: Entry, in parent: Int32, path: String, flags: Int32) throws {
        if unlinkat(parent, entry.bytes, flags) == 0 || errno == ENOENT { return }
        guard errno == EPERM else { throw failure("remove \(path)") }
        fchflags(parent, 0)
        let target = openat(parent, entry.bytes, O_RDONLY | O_SYMLINK | O_NONBLOCK | O_CLOEXEC)
        if target >= 0 {
            fchflags(target, 0)
            close(target)
        }
        if unlinkat(parent, entry.bytes, flags) == 0 || errno == ENOENT { return }
        throw failure("remove \(path)")
    }
}
