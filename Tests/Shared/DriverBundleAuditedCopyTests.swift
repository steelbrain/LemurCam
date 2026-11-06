import Darwin
@testable import LemurCam
import XCTest

/// Pins which copy of the driver counts a file's other hard links against the seal.
/// Any user can hard-link a file they can read, even a root-owned one, which raises
/// its link count but gives them no way to change it. On the staged copy (in a 0700
/// directory nobody else can reach) a second link means something is wrong; on the
/// installed copy, counting it would let anyone make a sealed driver look unsealed.
internal final class DriverBundleAuditedCopyTests: XCTestCase {
    private typealias Support = DriverInstallTestSupport
    private typealias Files = DriverBundleFiles
    private let bundle = LemurAudioHelper.driverBundleName

    private func audit(_ root: String, _ copy: Files.AuditedCopy) throws -> [String] {
        try Support.withDirectory(root) { Files.audit($0, name: bundle, owner: Support.owner, copy: copy) }
    }

    private func isSealed(_ root: String, _ copy: Files.AuditedCopy) throws -> Bool {
        try Support.withDirectory(root) { Files.isSealed($0, name: bundle, owner: Support.owner, copy: copy) }
    }

    func testOnlyTheStagedCopyRejectsAnotherLink() throws {
        let root = try Support.makeTemporaryDirectory()
        defer { Support.cleanUp(root) }
        let tree = try Support.makeDriver(in: root, version: "5")
        try Support.check(link("\(tree)/Contents/Info.plist", "\(root)/someone-elses-link"))

        XCTAssertEqual(try audit(root, .staged), ["\(bundle)/Contents/Info.plist: hard-linked"])
        XCTAssertFalse(try isSealed(root, .staged))
        XCTAssertEqual(try audit(root, .installed), [])
        XCTAssertTrue(try isSealed(root, .installed))
    }

    func testTheInstalledCopyStillReportsEverythingElse() throws {
        let root = try Support.makeTemporaryDirectory()
        defer { Support.cleanUp(root) }
        let tree = try Support.makeDriver(in: root, version: "5")
        try Support.check(link("\(tree)/Contents/Info.plist", "\(root)/someone-elses-link"))
        try Support.check(chmod("\(tree)/Contents/Info.plist", 0o666))
        try Support.check(symlink("/etc/hosts", "\(tree)/Contents/link"))

        XCTAssertEqual(try audit(root, .installed).sorted(), [
            "\(bundle)/Contents/Info.plist: writable by group or others",
            "\(bundle)/Contents/link: symbolic link"
        ])
        XCTAssertFalse(try isSealed(root, .installed))
    }
}
