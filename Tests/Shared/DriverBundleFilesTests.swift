import Darwin
@testable import LemurCam
import XCTest

/// Covers the descriptor-relative copy, audit, removal, and read the root helper
/// uses on driver bundles (audit finding C1): the installed tree must end up owned
/// by the install owner with no way for anyone else to modify it, and nothing a user
/// plants in a tree (symlinks, special files, hard links, ACLs, swapped entries) may
/// redirect a root operation outside it.
internal final class DriverBundleFilesTests: XCTestCase {
    private typealias Support = DriverInstallTestSupport
    private typealias Files = DriverBundleFiles
    private let owner = DriverInstallTestSupport.owner

    private func withScratch(_ body: (String) throws -> Void) throws {
        let root = try Support.makeTemporaryDirectory()
        defer { Support.cleanUp(root) }
        try body(root)
    }

    private func copy(_ source: String, into directory: String, name: String = "Copy.driver") throws {
        try Support.withDirectory(directory) { try Files.copyTree(from: source, to: $0, name: name, owner: owner) }
    }

    private func audit(_ directory: String, _ name: String, owner: Files.Owner? = nil) throws -> [String] {
        try Support.withDirectory(directory) { Files.audit($0, name: name, owner: owner ?? self.owner) }
    }

    // MARK: - Copy

    func testCopyIsSealedToOwnerWithCanonicalModes() throws {
        try withScratch { root in
            let source = try Support.makeDriver(in: root, version: "5")
            // Loose source modes: a world-writable plist, a setuid executable, a 0700 dir.
            try Support.check(chmod("\(source)/Contents/Info.plist", 0o666))
            try Support.check(chmod("\(source)/Contents/MacOS/LemurCamAudio", 0o4777))
            try Support.check(chmod("\(source)/Contents/_CodeSignature", 0o700))

            try copy(source, into: root)

            XCTAssertEqual(try audit(root, "Copy.driver"), [])
            XCTAssertEqual(Support.mode(of: "\(root)/Copy.driver"), 0o755)
            XCTAssertEqual(Support.mode(of: "\(root)/Copy.driver/Contents/Info.plist"), 0o644)
            XCTAssertEqual(Support.mode(of: "\(root)/Copy.driver/Contents/MacOS/LemurCamAudio"), 0o755)
            XCTAssertEqual(Support.mode(of: "\(root)/Copy.driver/Contents/_CodeSignature"), 0o755)
            XCTAssertEqual(
                FileManager.default.contents(atPath: "\(root)/Copy.driver/Contents/MacOS/LemurCamAudio"),
                Data(repeating: 0xCF, count: 4096)
            )
        }
    }

    func testCopyDoesNotCarrySourceACLs() throws {
        try withScratch { root in
            let source = try Support.makeDriver(in: root, version: "5")
            let plist = "\(source)/Contents/Info.plist"
            XCTAssertEqual(Support.run("/bin/chmod", ["+a", "everyone allow write", plist]), 0)
            XCTAssertTrue(try audit(root, LemurAudioHelper.driverBundleName).contains { $0.contains("access control") })

            try copy(source, into: root)
            XCTAssertEqual(try audit(root, "Copy.driver"), [])
        }
    }

    func testCopyRejectsSymlinksAnywhereInTheSource() throws {
        try withScratch { root in
            // Absolute, and relative to a file inside the bundle.
            for (index, target) in ["/etc/hosts", "Info.plist"].enumerated() {
                let source = try Support.makeDriver(in: root, version: "5", name: "Linked-\(index).driver")
                try Support.check(symlink(target, "\(source)/Contents/Extra"))
                XCTAssertThrowsError(try copy(source, into: root, name: "Out-\(index).driver")) { error in
                    XCTAssertTrue("\(error)".contains("symbolic link"), "\(error)")
                }
            }
        }
    }

    func testCopyRejectsASymlinkedBundleRoot() throws {
        try withScratch { root in
            let real = try Support.makeDriver(in: root, version: "5")
            try Support.check(symlink(real, "\(root)/Alias.driver"))
            XCTAssertThrowsError(try copy("\(root)/Alias.driver", into: root))
        }
    }

    func testCopyRejectsSpecialFilesWithoutBlocking() throws {
        try withScratch { root in
            let source = try Support.makeDriver(in: root, version: "5")
            try Support.check(mkfifo("\(source)/Contents/pipe", 0o644))
            XCTAssertThrowsError(try copy(source, into: root)) { error in
                XCTAssertTrue("\(error)".contains("unsupported file type"), "\(error)")
            }
        }
    }

    func testCopyOfHardLinkedFileIsAnIndependentFile() throws {
        try withScratch { root in
            let source = try Support.makeDriver(in: root, version: "5")
            let executable = "\(source)/Contents/MacOS/LemurCamAudio"
            try Support.check(link(executable, "\(root)/outside-link"))

            try copy(source, into: root)
            XCTAssertEqual(try audit(root, "Copy.driver"), [])
            try Support.write(Data("changed".utf8), to: executable, mode: 0o755)
            XCTAssertEqual(
                FileManager.default.contents(atPath: "\(root)/Copy.driver/Contents/MacOS/LemurCamAudio"),
                Data(repeating: 0xCF, count: 4096), "changing the source after the copy must not reach the copy"
            )
        }
    }

    func testCopyRefusesTreesNestedPastTheDepthLimit() throws {
        try withScratch { root in
            let deep = (0...Files.Limits.maxDepth).map { "d\($0)" }.joined(separator: "/")
            try FileManager.default.createDirectory(
                atPath: "\(root)/Deep.driver/\(deep)", withIntermediateDirectories: true
            )
            XCTAssertThrowsError(try copy("\(root)/Deep.driver", into: root))
        }
    }

    // MARK: - Audit

    func testAuditReportsEveryWayATreeCanBeModifiedByOthers() throws {
        try withScratch { root in
            let tree = try Support.makeDriver(in: root, version: "5")
            try Support.check(chmod("\(tree)/Contents/Info.plist", 0o664))
            try Support.check(chmod("\(tree)/Contents/MacOS", 0o2755))
            try Support.check(symlink("/etc/hosts", "\(tree)/Contents/link"))
            try Support.check(link("\(tree)/Contents/_CodeSignature/CodeResources", "\(root)/hardlink"))
            XCTAssertEqual(Support.run("/bin/chmod", ["+a", "everyone allow write", "\(tree)/Contents"]), 0)

            let problems = try audit(root, LemurAudioHelper.driverBundleName).joined(separator: "\n")
            XCTAssertTrue(problems.contains("Contents/Info.plist: writable by group or others"), problems)
            XCTAssertTrue(problems.contains("Contents/MacOS: has setuid, setgid, or sticky bits"), problems)
            XCTAssertTrue(problems.contains("Contents/link: symbolic link"), problems)
            XCTAssertTrue(problems.contains("CodeResources: hard-linked"), problems)
            XCTAssertTrue(problems.contains("Contents: has an access control list"), problems)
        }
    }

    func testAuditReportsEntriesOwnedBySomeoneElse() throws {
        try withScratch { root in
            try Support.makeDriver(in: root, version: "5")
            let other = Files.Owner(uid: owner.uid &+ 1, gid: owner.gid)
            let problems = try audit(root, LemurAudioHelper.driverBundleName, owner: other)
            XCTAssertFalse(problems.isEmpty)
            XCTAssertTrue(problems.allSatisfy { $0.contains("owned by") }, "\(problems)")
        }
    }

    func testIsSealedStopsAtTheFirstProblem() throws {
        try withScratch { root in
            let tree = try Support.makeDriver(in: root, version: "5")
            XCTAssertTrue(try Support.withDirectory(root) {
                Files.isSealed($0, name: LemurAudioHelper.driverBundleName, owner: owner)
            })
            XCTAssertFalse(try Support.withDirectory(root) { Files.isSealed($0, name: "Absent.driver", owner: owner) })

            try Support.check(chmod("\(tree)/Contents/Info.plist", 0o666))
            try Support.check(chmod("\(tree)/Contents/MacOS/LemurCamAudio", 0o777))
            XCTAssertEqual(try audit(root, LemurAudioHelper.driverBundleName).count, 2)
            let first = try Support.withDirectory(root) {
                Files.audit($0, name: LemurAudioHelper.driverBundleName, owner: owner, limit: 1)
            }
            XCTAssertEqual(first.count, 1)
            XCTAssertFalse(try Support.withDirectory(root) {
                Files.isSealed($0, name: LemurAudioHelper.driverBundleName, owner: owner)
            })
        }
    }

    // MARK: - Remove

    func testRemoveTreeDeletesTheTreeButNothingItLinksTo() throws {
        try withScratch { root in
            let outside = "\(root)/outside"
            try FileManager.default.createDirectory(atPath: outside, withIntermediateDirectories: false)
            try Support.write(Data("keep".utf8), to: "\(outside)/keep", mode: 0o644)
            let tree = try Support.makeDriver(in: root, version: "5")
            try Support.check(symlink(outside, "\(tree)/Contents/escape"))
            try Support.check(symlink("\(outside)/keep", "\(tree)/Contents/MacOS/keep"))

            try Support.withDirectory(root) { try Files.removeTree(at: $0, name: LemurAudioHelper.driverBundleName) }

            XCTAssertFalse(Support.exists(tree))
            XCTAssertEqual(FileManager.default.contents(atPath: "\(outside)/keep"), Data("keep".utf8))
        }
    }

    func testRemoveTreeClearsUserImmutableFlags() throws {
        try withScratch { root in
            let tree = try Support.makeDriver(in: root, version: "5")
            XCTAssertEqual(Support.run("/usr/bin/chflags", ["uchg", "\(tree)/Contents/Info.plist"]), 0)
            try Support.withDirectory(root) { try Files.removeTree(at: $0, name: LemurAudioHelper.driverBundleName) }
            XCTAssertFalse(Support.exists(tree))
        }
    }

    func testRemoveTreeOfMissingEntryIsNoOp() throws {
        try withScratch { root in
            XCTAssertNoThrow(try Support.withDirectory(root) { try Files.removeTree(at: $0, name: "absent") })
        }
    }

    // MARK: - Read

    private func version(in root: String, bundle: String = LemurAudioHelper.driverBundleName) throws -> String? {
        try Support.withDirectory(root) { Files.bundleVersion(at: $0, bundle: bundle) }
    }

    func testBundleVersionReadsWithoutFollowingSymlinks() throws {
        try withScratch { root in
            try Support.makeDriver(in: root, version: "9")
            XCTAssertEqual(try version(in: root), "9")

            // A planted symlink in any component must make the read fail, not follow it.
            let decoy = try Support.makeDriver(in: root, version: "1", name: "Decoy.driver")
            XCTAssertEqual(try version(in: root, bundle: "Decoy.driver"), "1")
            try Support.check(symlink(decoy, "\(root)/Linked.driver"))
            XCTAssertNil(try version(in: root, bundle: "Linked.driver"))

            let plist = "\(root)/\(LemurAudioHelper.driverBundleName)/Contents/Info.plist"
            try FileManager.default.removeItem(atPath: plist)
            try Support.check(symlink("\(decoy)/Contents/Info.plist", plist))
            XCTAssertNil(try version(in: root))
        }
    }
}
