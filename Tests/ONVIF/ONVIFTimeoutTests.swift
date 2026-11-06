@testable import LemurCam
import XCTest

/// `ONVIFTimeout.run` bounds the form fetches and the launch probe, which used to
/// rely on URLSession's idle timeout alone (a slow-dripping device never trips it).
internal final class ONVIFTimeoutTests: XCTestCase {
    func testReturnsResultWhenOperationFinishesInTime() async throws {
        let value = try await ONVIFTimeout.run(seconds: 5) { 42 }
        XCTAssertEqual(value, 42)
    }

    func testThrowsTimedOutAndCancelsHungOperation() async {
        let start = Date()
        do {
            _ = try await ONVIFTimeout.run(seconds: 0.2) { () async throws -> Int in
                try await Task.sleep(nanoseconds: 30_000_000_000)
                return 0
            }
            XCTFail("expected a timeout")
        } catch {
            guard case .timedOut? = error as? ONVIFError else {
                XCTFail("unexpected error \(error)")
                return
            }
        }
        // Cancellation reaches the hung operation, so the call returns promptly.
        XCTAssertLessThan(Date().timeIntervalSince(start), 5)
    }

    func testPropagatesOperationError() async {
        do {
            _ = try await ONVIFTimeout.run(seconds: 5) { () async throws -> Int in
                throw ONVIFError.authenticationFailed
            }
            XCTFail("expected the operation's error")
        } catch {
            guard case .authenticationFailed? = error as? ONVIFError else {
                XCTFail("unexpected error \(error)")
                return
            }
        }
    }

    func testTimedOutDescription() {
        XCTAssertEqual(ONVIFError.timedOut.errorDescription, "The camera did not respond in time")
    }
}
