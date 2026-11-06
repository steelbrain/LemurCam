import Darwin
import Foundation

/// The helper's install and uninstall pipeline for the driver bundle, run as root
/// against `/Library/Audio/Plug-Ins/HAL`. Parameterised by directory, owner, and
/// signature check so the same code runs against a temporary directory in tests.
///
/// Install: copy the source into a fresh private staging directory (0700, owned by
/// `owner`, unique per request) so no other user can touch the copy; give every
/// entry to `owner` with no group/other write; audit that; validate the code
/// signature of exactly those bytes; refuse a downgrade of a sealed installed copy
/// (an unsealed one is always replaced); then swap it into place with one atomic
/// rename. Removal of the previous copy and of staging never follows
/// symlinks. Callers must serialise operations (the helper runs them on one queue).
internal struct DriverInstaller {
    typealias Files = DriverBundleFiles

    /// Plug-ins directory the bundle is installed into.
    let pluginsDirectory: String
    /// File name of the installed bundle (e.g. `LemurCamAudio.driver`).
    let bundleName: String
    /// Owner of the plug-ins directory and of every installed entry.
    let owner: Files.Owner
    /// Validates the staged bundle at the given path; nil when acceptable, otherwise
    /// the reason it is not.
    let validateSignature: (String) -> String?

    /// Hidden per-request staging directories. Not `.driver` bundles, so coreaudiod
    /// never loads anything from them.
    static let stagingPrefix = ".LemurCamAudio.staging."
    /// Fixed staging name used by helpers before per-request staging; cleaned up.
    static let legacyStagingName = ".LemurCamAudio.driver.staging"

    // MARK: - Operations

    /// Install the bundle at `sourcePath`, replacing any installed copy. Throws with a
    /// user-presentable reason and leaves the installed copy untouched on failure.
    func install(from sourcePath: String) throws {
        let plugins = try openPluginsDirectory(create: true)
        defer { close(plugins) }
        removeStaleStaging(in: plugins)
        let staging = try makeStagingDirectory(in: plugins)
        defer {
            close(staging.descriptor)
            try? Files.removeTree(at: plugins, name: staging.name)
        }
        try Files.copyTree(from: sourcePath, to: staging.descriptor, name: bundleName, owner: owner)
        let problems = Files.audit(staging.descriptor, name: bundleName, owner: owner)
        guard problems.isEmpty else {
            throw Files.Failure(description: "Staged driver is not sealed: \(problems.joined(separator: "; "))")
        }
        let stagedPath = ((pluginsDirectory as NSString).appendingPathComponent(staging.name) as NSString)
            .appendingPathComponent(bundleName)
        if let failure = validateSignature(stagedPath) {
            throw Files.Failure(description: "Driver signature validation failed: \(failure)")
        }
        // Only a copy sealed to `owner` has a version worth defending. One that
        // anyone else can write to (every copy installed before the helper sealed
        // them was user-owned) could carry any CFBundleVersion, and must be
        // replaced, not allowed to block every later install.
        if Files.isSealed(plugins, name: bundleName, owner: owner),
           let installed = Files.bundleVersion(at: plugins, bundle: bundleName),
           let staged = Files.bundleVersion(at: staging.descriptor, bundle: bundleName),
           Self.isDowngrade(from: installed, to: staged) {
            throw Files.Failure(description:
                "Refusing to replace driver version \(installed) with older version \(staged). " +
                "Remove the microphone first to install an older build.")
        }
        try moveIntoPlace(from: staging.descriptor, plugins: plugins)
    }

    /// Remove the installed bundle. Returns false if none was installed.
    @discardableResult
    func uninstall() throws -> Bool {
        guard let plugins = try openExistingPluginsDirectory() else { return false }
        defer { close(plugins) }
        removeStaleStaging(in: plugins)
        guard try Files.status(at: plugins, Files.Entry(bundleName)) != nil else { return false }
        let staging = try makeStagingDirectory(in: plugins)
        defer {
            close(staging.descriptor)
            try? Files.removeTree(at: plugins, name: staging.name)
        }
        // Out of the scanned directory in one rename; the deferred removal then
        // deletes it from the private staging directory without following symlinks.
        try Files.check(
            renameatx_np(plugins, bundleName, staging.descriptor, bundleName, UInt32(RENAME_EXCL)),
            "move \(bundleName) out of the plug-ins directory"
        )
        return true
    }

    /// `CFBundleVersion` of the installed bundle, read without following symlinks.
    func installedVersion() -> String? {
        guard let plugins = try? openExistingPluginsDirectory() else { return nil }
        defer { close(plugins) }
        return Files.bundleVersion(at: plugins, bundle: bundleName)
    }

    /// Whether the installed bundle exists and is sealed to `owner` (the same audit
    /// the staged copy passes) in a plug-ins directory only `owner` can write.
    /// Read-only, so the app runs it as the user to tell a copy the helper sealed
    /// from one an older helper installed user-owned.
    func installedCopyIsSealed() -> Bool {
        guard let plugins = try? openExistingPluginsDirectory() else { return false }
        defer { close(plugins) }
        return Files.isSealed(plugins, name: bundleName, owner: owner)
    }

    /// True when `staged` is numerically older than `installed`. Equal versions
    /// reinstall (repair); a version that is not dot-separated integers is never
    /// treated as a downgrade, since every signed build uses integer build numbers.
    /// An explicit downgrade is uninstall followed by install.
    static func isDowngrade(from installed: String, to staged: String) -> Bool {
        let installedParts = installed.split(separator: ".", omittingEmptySubsequences: false)
        let stagedParts = staged.split(separator: ".", omittingEmptySubsequences: false)
        for index in 0..<max(installedParts.count, stagedParts.count) {
            let lhs = index < installedParts.count ? installedParts[index] : "0"
            let rhs = index < stagedParts.count ? stagedParts[index] : "0"
            guard let installedNumber = Int(lhs), let stagedNumber = Int(rhs) else { return false }
            if installedNumber != stagedNumber { return stagedNumber < installedNumber }
        }
        return false
    }

    // MARK: - Steps

    /// Open the plug-ins directory (creating it if asked) and require that only
    /// `owner` can write to it: if anyone else could, nothing installed in it is safe.
    private func openPluginsDirectory(create: Bool) throws -> Int32 {
        if create, !FileManager.default.fileExists(atPath: pluginsDirectory) {
            try FileManager.default.createDirectory(
                atPath: pluginsDirectory, withIntermediateDirectories: true,
                attributes: [.posixPermissions: 0o755]
            )
        }
        let plugins = try Files.openDirectory(pluginsDirectory)
        var info = stat()
        guard fstat(plugins, &info) == 0, info.st_uid == owner.uid, info.st_mode & 0o022 == 0 else {
            close(plugins)
            throw Files.Failure(description: "The plug-ins directory is not owned by root or is writable by others")
        }
        return plugins
    }

    private func openExistingPluginsDirectory() throws -> Int32? {
        guard FileManager.default.fileExists(atPath: pluginsDirectory) else { return nil }
        return try openPluginsDirectory(create: false)
    }

    /// Remove staging left behind by an interrupted operation (or by older helpers,
    /// whose staging copy could be user-owned). Best effort.
    private func removeStaleStaging(in plugins: Int32) {
        guard let names = try? Files.entries(of: plugins) else { return }
        let stale = names.filter { $0.display.hasPrefix(Self.stagingPrefix) || $0.display == Self.legacyStagingName }
        for entry in stale {
            try? Files.removeTree(at: plugins, name: entry.display)
        }
    }

    /// A new 0700 directory with an unguessable name, created relative to `plugins`.
    private func makeStagingDirectory(in plugins: Int32) throws -> (name: String, descriptor: Int32) {
        for _ in 0..<8 {
            let name = Self.stagingPrefix + String(UInt64.random(in: 0...UInt64.max), radix: 36)
            if mkdirat(plugins, name, 0o700) != 0 {
                if errno == EEXIST { continue }
                throw Files.failure("create staging directory")
            }
            let descriptor = try Files.openDirectory(at: plugins, Files.Entry(name))
            var info = stat()
            guard fstat(descriptor, &info) == 0, info.st_uid == owner.uid, info.st_mode & 0o077 == 0 else {
                close(descriptor)
                throw Files.Failure(description: "Staging directory has unexpected ownership")
            }
            return (name, descriptor)
        }
        throw Files.Failure(description: "Could not create a unique staging directory")
    }

    /// Put the staged bundle in place with one rename: swap it with the installed
    /// copy (which lands in staging, to be removed with it), or a plain exclusive
    /// rename when nothing is installed.
    private func moveIntoPlace(from staging: Int32, plugins: Int32) throws {
        let swap = try Files.status(at: plugins, Files.Entry(bundleName)) != nil
        let flags = UInt32(swap ? RENAME_SWAP : RENAME_EXCL)
        if renameatx_np(staging, bundleName, plugins, bundleName, flags) == 0 { return }
        guard swap, errno == ENOTSUP || errno == EINVAL else {
            throw Files.failure("install \(bundleName)")
        }
        // A volume without RENAME_SWAP: move the old copy aside first.
        try Files.check(
            renameatx_np(plugins, bundleName, staging, "previous", UInt32(RENAME_EXCL)),
            "move the installed \(bundleName) aside"
        )
        try Files.check(
            renameatx_np(staging, bundleName, plugins, bundleName, UInt32(RENAME_EXCL)),
            "install \(bundleName)"
        )
    }
}
