import CoreMedia
@testable import LemurCam
import XCTest

/// Pins the extension's CMTime → nanoseconds conversion. The sink stream used to
/// compute `UInt64(pts.seconds * 1e9)` directly, which traps (crashing the camera
/// extension) on an invalid, indefinite, infinite, NaN or negative timestamp.
internal final class HostTimeNanosecondsTests: XCTestCase {

    private let fallbackTime = CMTime(value: 7, timescale: 1)
    private let fallbackNanoseconds: UInt64 = 7_000_000_000

    // MARK: - Valid timestamps

    func testConvertsNumericTimes() {
        XCTAssertEqual(HostTimeNanoseconds.nanoseconds(CMTime(value: 3, timescale: 2)), 1_500_000_000)
        XCTAssertEqual(HostTimeNanoseconds.nanoseconds(CMTime(value: 0, timescale: 600)), 0)
        XCTAssertEqual(HostTimeNanoseconds.nanoseconds(CMTime(value: 1, timescale: 1_000_000_000)), 1)
    }

    func testValidTimeIgnoresTheFallback() {
        var fallbackCalls = 0
        let result = HostTimeNanoseconds.nanoseconds(CMTime(value: 2, timescale: 1)) {
            fallbackCalls += 1
            return self.fallbackTime
        }
        XCTAssertEqual(result, 2_000_000_000)
        XCTAssertEqual(fallbackCalls, 0)
    }

    // MARK: - Timestamps that used to trap

    func testRejectsNonNumericTimes() {
        for time in [CMTime.invalid, .indefinite, .positiveInfinity, .negativeInfinity] {
            XCTAssertNil(HostTimeNanoseconds.nanoseconds(time), "\(time)")
            XCTAssertEqual(
                HostTimeNanoseconds.nanoseconds(time) { self.fallbackTime },
                fallbackNanoseconds,
                "\(time)"
            )
        }
    }

    func testRejectsNegativeTimes() {
        let negative = CMTime(value: -1, timescale: 1)
        XCTAssertNil(HostTimeNanoseconds.nanoseconds(negative))
        XCTAssertEqual(HostTimeNanoseconds.nanoseconds(negative) { self.fallbackTime }, fallbackNanoseconds)
    }

    func testRejectsTimesTooLargeForUInt64Nanoseconds() {
        // Int64.max seconds is ~9.2e27 ns, far past UInt64.max (~1.8e19).
        let huge = CMTime(value: .max, timescale: 1)
        XCTAssertNil(HostTimeNanoseconds.nanoseconds(huge))
        XCTAssertEqual(HostTimeNanoseconds.nanoseconds(huge) { self.fallbackTime }, fallbackNanoseconds)
    }

    func testRejectsNaNFromZeroTimescale() {
        // Flagged valid but with a zero timescale: `seconds` is not a finite number.
        let zeroScale = CMTime(value: 1, timescale: 0, flags: .valid, epoch: 0)
        XCTAssertNil(HostTimeNanoseconds.nanoseconds(zeroScale))
    }

    func testFallsBackToZeroWhenTheFallbackIsInvalidToo() {
        XCTAssertEqual(HostTimeNanoseconds.nanoseconds(.invalid) { .invalid }, 0)
    }

    // MARK: - Host clock

    func testNowAndInvalidFallbackUseTheHostClock() {
        let before = HostTimeNanoseconds.now()
        let fromInvalid = HostTimeNanoseconds.nanosecondsOrNow(.invalid)
        let after = HostTimeNanoseconds.now()
        XCTAssertGreaterThan(before, 0)
        XCTAssertGreaterThanOrEqual(fromInvalid, before)
        XCTAssertLessThanOrEqual(fromInvalid, after)
    }
}
