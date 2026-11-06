import CoreMediaIO
@testable import LemurCam
import XCTest

/// The CMIO device list is read in two calls, its size and then its data, and the
/// list can change in between. A read that may not hold the whole list used to be
/// taken as it was, so a listed device could look gone; it is now read again, and
/// counts as unreadable (which keeps everything) when every read was like that. No
/// CMIO device is touched: the reads are made up.
internal final class CMIODeviceListReadTests: XCTestCase {
    private static let idSize = UInt32(MemoryLayout<CMIODeviceID>.stride)

    /// A read whose sizes are counted in device IDs.
    private func attempt(
        sizeBefore: Int, buffer: [CMIODeviceID], dataUsed: Int, sizeAfter: Int
    ) -> CMIODeviceListRead.Attempt {
        CMIODeviceListRead.Attempt(
            sizeBefore: UInt32(sizeBefore) * Self.idSize, buffer: buffer,
            dataUsed: UInt32(dataUsed) * Self.idSize, sizeAfter: UInt32(sizeAfter) * Self.idSize
        )
    }

    // MARK: - One read

    func testAConsistentReadIsKept() {
        let read = attempt(sizeBefore: 3, buffer: [31, 47, 52], dataUsed: 3, sizeAfter: 3)
        XCTAssertTrue(read.holdsWholeList)
        XCTAssertEqual(read.deviceIDs, [31, 47, 52])
    }

    func testAnEmptyListIsKept() {
        let read = attempt(sizeBefore: 0, buffer: [], dataUsed: 0, sizeAfter: 0)
        XCTAssertTrue(read.holdsWholeList)
        XCTAssertEqual(read.deviceIDs, [])
    }

    /// CMIO filled less than the size it gave just before, and the zeros left at the
    /// end of the buffer used to be read as device IDs.
    func testAShortReadIsNotKept() {
        let read = attempt(sizeBefore: 3, buffer: [31, 47, 0], dataUsed: 2, sizeAfter: 3)
        XCTAssertFalse(read.holdsWholeList)
        XCTAssertEqual(read.deviceIDs, [31, 47], "only the IDs the read filled")
    }

    /// A device was added after the size was read: the buffer was filled to the end
    /// and may be missing a listed device, which then looked gone.
    func testAListThatGrewIsNotKept() {
        XCTAssertFalse(attempt(sizeBefore: 2, buffer: [31, 52], dataUsed: 2, sizeAfter: 3).holdsWholeList)
    }

    func testAListThatShrankIsNotKept() {
        XCTAssertFalse(attempt(sizeBefore: 3, buffer: [31, 52, 0], dataUsed: 2, sizeAfter: 2).holdsWholeList)
        XCTAssertFalse(attempt(sizeBefore: 3, buffer: [31, 47, 52], dataUsed: 3, sizeAfter: 2).holdsWholeList)
    }

    func testAReadThatIsNotWholeIDsInItsBufferIsNotKept() {
        let size = Self.idSize + 1
        let partialID = CMIODeviceListRead.Attempt(sizeBefore: size, buffer: [31], dataUsed: size, sizeAfter: size)
        XCTAssertFalse(partialID.holdsWholeList)
        XCTAssertFalse(attempt(sizeBefore: 2, buffer: [31], dataUsed: 2, sizeAfter: 2).holdsWholeList)
    }

    // MARK: - Reading again

    func testTheListIsReadAgainUntilAReadHoldsItAll() throws {
        var reads = [
            attempt(sizeBefore: 2, buffer: [31, 52], dataUsed: 2, sizeAfter: 3),
            attempt(sizeBefore: 3, buffer: [31, 47, 52], dataUsed: 3, sizeAfter: 3)
        ]
        var count = 0
        let deviceIDs = try CMIODeviceListRead.read {
            count += 1
            return reads.removeFirst()
        }
        XCTAssertEqual(deviceIDs, [31, 47, 52])
        XCTAssertEqual(count, 2)
    }

    /// A list that changed during every read is unreadable, which keeps the cached
    /// device and every retired sink queue (`CMIODeviceList.unreadable`).
    func testAListThatKeepsChangingIsUnreadableAfterTheLastAttempt() {
        XCTAssertGreaterThan(CMIODeviceListRead.maxAttempts, 1)
        var count = 0
        XCTAssertThrowsError(try CMIODeviceListRead.read {
            count += 1
            return self.attempt(
                sizeBefore: count, buffer: Array(repeating: 31, count: count), dataUsed: count, sizeAfter: count + 1
            )
        }) { error in
            XCTAssertEqual((error as? CMIODeviceListRead.KeptChanging)?.attempts, CMIODeviceListRead.maxAttempts)
        }
        XCTAssertEqual(count, CMIODeviceListRead.maxAttempts)
    }

    func testAFailedReadIsThrownAtOnce() {
        struct ReadFailed: Error {}
        var count = 0
        XCTAssertThrowsError(try CMIODeviceListRead.read { () throws -> CMIODeviceListRead.Attempt in
            count += 1
            throw ReadFailed()
        }) { error in
            XCTAssertTrue(error is ReadFailed)
        }
        XCTAssertEqual(count, 1)
    }
}
