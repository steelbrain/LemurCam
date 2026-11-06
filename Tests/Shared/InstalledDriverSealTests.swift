import Darwin
@testable import LemurCam
import XCTest

/// The app's own check of the installed driver (`DriverInstaller.installedCopyIsSealed`),
/// run against a temporary plug-ins directory with the current user standing in for
/// root. The app cannot trust the helper for this: a helper from before an app update
/// can still be serving, and every copy those helpers installed is user-owned.
internal final class InstalledDriverSealTests: XCTestCase {
    private typealias Support = DriverInstallTestSupport

    private final class Scratch {
        let root: String
        let plugins: String

        init() throws {
            root = try Support.makeTemporaryDirectory()
            plugins = (root as NSString).appendingPathComponent("HAL")
            try FileManager.default.createDirectory(atPath: plugins, withIntermediateDirectories: false)
            try Support.check(chmod(plugins, 0o755))
        }

        deinit { Support.cleanUp(root) }

        var installedPath: String { (plugins as NSString).appendingPathComponent(LemurAudioHelper.driverBundleName) }

        func installer() -> DriverInstaller {
            DriverInstaller(
                pluginsDirectory: plugins, bundleName: LemurAudioHelper.driverBundleName,
                owner: Support.owner, validateSignature: { _ in nil }
            )
        }

        func installSealedCopy() throws {
            let sources = (root as NSString).appendingPathComponent("app")
            try FileManager.default.createDirectory(atPath: sources, withIntermediateDirectories: false)
            try installer().install(from: Support.makeDriver(in: sources, version: "6"))
        }
    }

    func testCopyTheHelperSealedIsSealed() throws {
        let scratch = try Scratch()
        try scratch.installSealedCopy()
        XCTAssertTrue(scratch.installer().installedCopyIsSealed())
    }

    func testNoInstalledCopyIsNotSealed() throws {
        let scratch = try Scratch()
        XCTAssertFalse(scratch.installer().installedCopyIsSealed())

        try FileManager.default.removeItem(atPath: scratch.plugins)
        XCTAssertFalse(scratch.installer().installedCopyIsSealed(), "no plug-ins directory at all")
    }

    func testCopyOthersCanModifyIsNotSealed() throws {
        let cases: [(String, mode_t)] = [
            ("", 0o775), // the bundle directory itself
            ("/Contents/MacOS/LemurCamAudio", 0o777),
            ("/Contents/Info.plist", 0o646)
        ]
        for (entry, mode) in cases {
            let scratch = try Scratch()
            try scratch.installSealedCopy()
            try Support.check(chmod(scratch.installedPath + entry, mode))
            XCTAssertFalse(scratch.installer().installedCopyIsSealed(), "\(entry) at \(String(mode, radix: 8))")
        }
    }

    func testCopyOwnedBySomeoneElseIsNotSealed() throws {
        let scratch = try Scratch()
        try scratch.installSealedCopy()
        let other = DriverInstaller(
            pluginsDirectory: scratch.plugins, bundleName: LemurAudioHelper.driverBundleName,
            owner: DriverBundleFiles.Owner(uid: Support.owner.uid &+ 1, gid: Support.owner.gid),
            validateSignature: { _ in nil }
        )
        XCTAssertFalse(other.installedCopyIsSealed())
    }

    func testSymlinkedInstallIsNotSealed() throws {
        let scratch = try Scratch()
        let elsewhere = (scratch.root as NSString).appendingPathComponent("elsewhere")
        try FileManager.default.createDirectory(atPath: elsewhere, withIntermediateDirectories: false)
        let real = try Support.makeDriver(in: elsewhere, version: "6")
        try Support.check(symlink(real, scratch.installedPath))
        XCTAssertFalse(scratch.installer().installedCopyIsSealed())
    }

    func testPluginsDirectoryOthersCanWriteIsNotSealed() throws {
        let scratch = try Scratch()
        try scratch.installSealedCopy()
        try Support.check(chmod(scratch.plugins, 0o777))
        XCTAssertFalse(scratch.installer().installedCopyIsSealed())
    }
}
