import Darwin
import Foundation
@testable import LemurCam

/// Temporary directory trees for the driver-install tests. Everything runs as the
/// current user, with the current user standing in for root:wheel as the owner.
internal enum DriverInstallTestSupport {
    static let owner = DriverBundleFiles.Owner(uid: getuid(), gid: getgid())

    /// A fresh directory (symlinks in its path resolved), removed by `cleanUp`.
    static func makeTemporaryDirectory() throws -> String {
        let base = URL(fileURLWithPath: NSTemporaryDirectory()).resolvingSymlinksInPath()
        let url = base.appendingPathComponent("lemur-driver-tests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        try check(chmod(url.path, 0o755))
        return url.path
    }

    /// Remove a test tree, clearing any immutable flags the test set first.
    static func cleanUp(_ path: String) {
        _ = run("/usr/bin/chflags", ["-R", "nouchg", path])
        try? FileManager.default.removeItem(atPath: path)
    }

    /// Lay out a minimal driver bundle: Info.plist with `version`, an executable,
    /// and a code-signature placeholder. Returns the bundle path.
    @discardableResult
    static func makeDriver(in directory: String, version: String,
                           name: String = LemurAudioHelper.driverBundleName) throws -> String {
        let bundle = (directory as NSString).appendingPathComponent(name)
        let contents = (bundle as NSString).appendingPathComponent("Contents")
        for sub in ["MacOS", "_CodeSignature"] {
            try FileManager.default.createDirectory(
                atPath: (contents as NSString).appendingPathComponent(sub), withIntermediateDirectories: true
            )
        }
        let plist = try PropertyListSerialization.data(
            fromPropertyList: ["CFBundleVersion": version, "CFBundleIdentifier": "cam.lemur.app.audio"],
            format: .xml, options: 0
        )
        try write(plist, to: (contents as NSString).appendingPathComponent("Info.plist"), mode: 0o644)
        try write(Data(repeating: 0xCF, count: 4096), to: "\(contents)/MacOS/LemurCamAudio", mode: 0o755)
        try write(Data("resources".utf8), to: "\(contents)/_CodeSignature/CodeResources", mode: 0o644)
        return bundle
    }

    static func write(_ data: Data, to path: String, mode: mode_t) throws {
        try data.write(to: URL(fileURLWithPath: path))
        try check(chmod(path, mode))
    }

    static func mode(of path: String) -> mode_t? {
        var info = stat()
        guard lstat(path, &info) == 0 else { return nil }
        return info.st_mode & 0o7777
    }

    static func exists(_ path: String) -> Bool {
        var info = stat()
        return lstat(path, &info) == 0
    }

    /// Run a tool, returning its exit status.
    @discardableResult
    static func run(_ tool: String, _ arguments: [String]) -> Int32 {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: tool)
        process.arguments = arguments
        process.standardError = FileHandle.nullDevice
        do {
            try process.run()
            process.waitUntilExit()
            return process.terminationStatus
        } catch {
            return -1
        }
    }

    /// Run `body` with an open descriptor for `directory`.
    static func withDirectory<T>(_ directory: String, _ body: (Int32) throws -> T) throws -> T {
        let descriptor = try DriverBundleFiles.openDirectory(directory)
        defer { close(descriptor) }
        return try body(descriptor)
    }

    static func check(_ result: Int32, line: UInt = #line) throws {
        guard result == 0 else {
            throw DriverBundleFiles.Failure(description: "setup call failed at line \(line): errno \(errno)")
        }
    }
}
