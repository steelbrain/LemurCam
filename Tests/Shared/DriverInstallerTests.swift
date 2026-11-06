import Darwin
@testable import LemurCam
import XCTest

/// Runs the helper's install pipeline (`DriverInstaller`) against a temporary
/// plug-ins directory, with the current user standing in for root. Covers the C1
/// ordering (private staging, sealed copy, then signature check, then one rename),
/// per-request staging (C11), and downgrade refusal (C10).
internal final class DriverInstallerTests: XCTestCase {
    private typealias Support = DriverInstallTestSupport
    private let bundleName = LemurAudioHelper.driverBundleName

    private final class Scratch {
        let root: String
        let plugins: String
        let sources: String
        var validatedPaths: [String] = []
        var signatureFailure: String?
        /// Checks run on the staged copy at validation time.
        var stagedChecks: [String] = []

        init() throws {
            root = try Support.makeTemporaryDirectory()
            plugins = (root as NSString).appendingPathComponent("HAL")
            sources = (root as NSString).appendingPathComponent("apps")
            try FileManager.default.createDirectory(atPath: plugins, withIntermediateDirectories: false)
            try FileManager.default.createDirectory(atPath: sources, withIntermediateDirectories: false)
            try Support.check(chmod(plugins, 0o755))
        }

        deinit { Support.cleanUp(root) }

        func installer() -> DriverInstaller {
            DriverInstaller(
                pluginsDirectory: plugins, bundleName: LemurAudioHelper.driverBundleName,
                owner: Support.owner,
                validateSignature: { [weak self] path in
                    guard let self else { return "scratch released" }
                    self.validatedPaths.append(path)
                    let staging = (path as NSString).deletingLastPathComponent
                    self.stagedChecks.append("staging mode \(String(Support.mode(of: staging) ?? 0, radix: 8))")
                    return self.signatureFailure
                }
            )
        }

        /// A source app bundle's driver at `version`, in its own directory.
        func source(version: String) throws -> String {
            let directory = (sources as NSString).appendingPathComponent("v\(version)-\(UUID().uuidString)")
            try FileManager.default.createDirectory(atPath: directory, withIntermediateDirectories: false)
            return try Support.makeDriver(in: directory, version: version)
        }

        var installedPath: String { (plugins as NSString).appendingPathComponent(LemurAudioHelper.driverBundleName) }

        func pluginsEntries() throws -> [String] {
            try FileManager.default.contentsOfDirectory(atPath: plugins).sorted()
        }
    }

    func testInstallStagesPrivatelyValidatesTheSealedCopyAndInstallsIt() throws {
        let scratch = try Scratch()
        try scratch.installer().install(from: scratch.source(version: "5"))

        XCTAssertEqual(scratch.installer().installedVersion(), "5")
        XCTAssertEqual(try scratch.pluginsEntries(), [bundleName], "staging must be gone afterwards")
        let audit = try Support.withDirectory(scratch.plugins) {
            DriverBundleFiles.audit($0, name: bundleName, owner: Support.owner, copy: .installed)
        }
        XCTAssertEqual(audit, [])
        // The signature was checked on the staged copy in a private directory, not on
        // the source path the caller controls.
        let validated = try XCTUnwrap(scratch.validatedPaths.first)
        let stagingName = ((validated as NSString).deletingLastPathComponent as NSString).lastPathComponent
        XCTAssertTrue(stagingName.hasPrefix(DriverInstaller.stagingPrefix), validated)
        XCTAssertEqual(scratch.stagedChecks, ["staging mode 700"])
    }

    func testEachRequestUsesItsOwnStagingDirectory() throws {
        let scratch = try Scratch()
        try scratch.installer().install(from: scratch.source(version: "5"))
        try scratch.installer().install(from: scratch.source(version: "6"))
        XCTAssertEqual(Set(scratch.validatedPaths).count, 2)
    }

    func testUpgradeReplacesTheInstalledCopyAndRemovesTheOldOne() throws {
        let scratch = try Scratch()
        try scratch.installer().install(from: scratch.source(version: "5"))
        try scratch.installer().install(from: scratch.source(version: "6"))

        XCTAssertEqual(scratch.installer().installedVersion(), "6")
        XCTAssertEqual(try scratch.pluginsEntries(), [bundleName])
    }

    func testDowngradeIsRefusedAndTheInstalledCopyKept() throws {
        let scratch = try Scratch()
        try scratch.installer().install(from: scratch.source(version: "7"))
        XCTAssertThrowsError(try scratch.installer().install(from: scratch.source(version: "5"))) { error in
            XCTAssertTrue("\(error)".contains("older version 5"), "\(error)")
        }
        XCTAssertEqual(scratch.installer().installedVersion(), "7")
        XCTAssertEqual(try scratch.pluginsEntries(), [bundleName])
    }

    func testSomeoneElsesHardLinkDoesNotLiftTheDowngradeRefusal() throws {
        // Any user can hard-link a file of the installed copy they can read. That
        // changes nothing about who can modify it, so the copy is still sealed and
        // its version still blocks an older install.
        let scratch = try Scratch()
        try scratch.installer().install(from: scratch.source(version: "7"))
        let elsewhere = (scratch.root as NSString).appendingPathComponent("someone-elses-link")
        try Support.check(link("\(scratch.installedPath)/Contents/MacOS/LemurCamAudio", elsewhere))

        XCTAssertThrowsError(try scratch.installer().install(from: scratch.source(version: "5"))) { error in
            XCTAssertTrue("\(error)".contains("older version 5"), "\(error)")
        }
        XCTAssertEqual(scratch.installer().installedVersion(), "7")
    }

    func testUnsealedInstalledCopyIsReplacedWhateverVersionItClaims() throws {
        // Copies installed before the helper sealed them were user-owned, so anything
        // running as the user could rewrite their version. A version read from such a
        // copy must not block the install (or keep that copy in place).
        let loosen: [(String, mode_t)] = [("Contents/Info.plist", 0o666), ("Contents/MacOS", 0o777)]
        for (entry, mode) in loosen {
            let scratch = try Scratch()
            try Support.makeDriver(in: scratch.plugins, version: "999")
            try Support.check(chmod("\(scratch.installedPath)/\(entry)", mode))

            XCTAssertNoThrow(try scratch.installer().install(from: scratch.source(version: "6")), entry)
            XCTAssertEqual(scratch.installer().installedVersion(), "6", entry)
            let audit = try Support.withDirectory(scratch.plugins) {
                DriverBundleFiles.audit($0, name: bundleName, owner: Support.owner, copy: .installed)
            }
            XCTAssertEqual(audit, [], entry)
        }
    }

    func testSameVersionReinstallAndUninstallThenOlderInstallAreAllowed() throws {
        let scratch = try Scratch()
        try scratch.installer().install(from: scratch.source(version: "7"))
        XCTAssertNoThrow(try scratch.installer().install(from: scratch.source(version: "7")), "repair")

        XCTAssertTrue(try scratch.installer().uninstall())
        XCTAssertNoThrow(try scratch.installer().install(from: scratch.source(version: "5")), "explicit downgrade")
        XCTAssertEqual(scratch.installer().installedVersion(), "5")
    }

    func testSignatureFailureInstallsNothingAndLeavesNoStaging() throws {
        let scratch = try Scratch()
        scratch.signatureFailure = "not signed by the team"
        XCTAssertThrowsError(try scratch.installer().install(from: scratch.source(version: "5"))) { error in
            XCTAssertTrue("\(error)".contains("not signed by the team"), "\(error)")
        }
        XCTAssertEqual(try scratch.pluginsEntries(), [])
    }

    func testSymlinkInSourceInstallsNothing() throws {
        let scratch = try Scratch()
        let source = try scratch.source(version: "5")
        try Support.check(symlink("/etc/hosts", "\(source)/Contents/MacOS/LemurCamAudio2"))
        XCTAssertThrowsError(try scratch.installer().install(from: source))
        XCTAssertTrue(scratch.validatedPaths.isEmpty, "nothing is validated before the copy is sealed")
        XCTAssertEqual(try scratch.pluginsEntries(), [])
    }

    func testStaleStagingIsRemovedAndOtherPlugInsAreLeftAlone() throws {
        let scratch = try Scratch()
        let leftover = (scratch.plugins as NSString).appendingPathComponent(DriverInstaller.stagingPrefix + "crashed")
        try FileManager.default.createDirectory(atPath: leftover, withIntermediateDirectories: false)
        try Support.makeDriver(in: leftover, version: "3")
        try Support.makeDriver(in: scratch.plugins, version: "1", name: DriverInstaller.legacyStagingName)
        try Support.makeDriver(in: scratch.plugins, version: "1", name: "Other.driver")

        try scratch.installer().install(from: scratch.source(version: "5"))
        XCTAssertEqual(try scratch.pluginsEntries(), [bundleName, "Other.driver"].sorted())
    }

    func testUninstallRemovesTheInstalledCopyWithoutFollowingItsSymlinks() throws {
        let scratch = try Scratch()
        let outside = (scratch.root as NSString).appendingPathComponent("outside")
        try FileManager.default.createDirectory(atPath: outside, withIntermediateDirectories: false)
        try Support.write(Data("keep".utf8), to: "\(outside)/keep", mode: 0o644)
        // A copy installed by an older helper was user-owned, so it may hold anything.
        try Support.makeDriver(in: scratch.plugins, version: "4")
        try Support.check(symlink(outside, "\(scratch.installedPath)/Contents/escape"))

        XCTAssertTrue(try scratch.installer().uninstall())
        XCTAssertEqual(try scratch.pluginsEntries(), [])
        XCTAssertEqual(FileManager.default.contents(atPath: "\(outside)/keep"), Data("keep".utf8))
        XCTAssertFalse(try scratch.installer().uninstall(), "nothing left to remove")
    }

    func testPluginsDirectoryWritableByOthersIsRefused() throws {
        let scratch = try Scratch()
        try Support.check(chmod(scratch.plugins, 0o777))
        XCTAssertThrowsError(try scratch.installer().install(from: scratch.source(version: "5")))
        XCTAssertEqual(try scratch.pluginsEntries(), [])
    }

    func testIsDowngradeComparesBuildNumbersNumerically() {
        XCTAssertTrue(DriverInstaller.isDowngrade(from: "10", to: "9"))
        XCTAssertTrue(DriverInstaller.isDowngrade(from: "5.1", to: "5"))
        XCTAssertFalse(DriverInstaller.isDowngrade(from: "9", to: "10"))
        XCTAssertFalse(DriverInstaller.isDowngrade(from: "5", to: "5.0"))
        XCTAssertFalse(DriverInstaller.isDowngrade(from: "5", to: "5"))
        XCTAssertFalse(DriverInstaller.isDowngrade(from: "abc", to: "1"), "unparseable versions never block")
    }

    func testShippedDriverSignatureSurvivesTheCopy() throws {
        let shipped = LemurAudioHelper.bundledDriverPath(inAppBundle: Bundle.main.bundlePath)
        guard FileManager.default.fileExists(atPath: shipped),
              LemurAudioHelper.validateSignature(path: shipped, requirement: LemurAudioHelper.driverRequirement) == nil
        else {
            throw XCTSkip("no team-signed driver in the test host (unsigned CI build)")
        }
        let scratch = try Scratch()
        let requirement = LemurAudioHelper.driverRequirement
        let installer = DriverInstaller(
            pluginsDirectory: scratch.plugins, bundleName: bundleName, owner: Support.owner,
            validateSignature: { LemurAudioHelper.validateSignature(path: $0, requirement: requirement) }
        )
        XCTAssertNoThrow(try installer.install(from: shipped), "the strict flags must accept a byte copy")
    }
}
