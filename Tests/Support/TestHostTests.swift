@testable import LemurCam
import XCTest

/// Pins the one test-host check every app-lifecycle entry point uses. Becoming active
/// used to skip it, so if xcodebuild activated the host it sent a real camera query
/// and helper XPC call, which could write restart markers into the real app's
/// defaults.
internal final class TestHostTests: XCTestCase {
    func testTheTestConfigurationInTheEnvironmentMarksTheHost() {
        XCTAssertTrue(TestHost.detect(
            environment: ["XCTestConfigurationFilePath": "/tmp/config.xctestconfiguration"],
            testCaseClassLoaded: false
        ))
    }

    func testALoadedTestBundleMarksTheHost() {
        XCTAssertTrue(TestHost.detect(environment: [:], testCaseClassLoaded: true))
    }

    func testTheAppItselfIsNotTheHost() {
        XCTAssertFalse(TestHost.detect(environment: [:], testCaseClassLoaded: false))
        XCTAssertFalse(TestHost.detect(environment: ["HOME": "/Users/someone"], testCaseClassLoaded: false))
    }

    func testThisProcessIsTheHost() {
        // These tests run inside the app as their host, where the guard must hold.
        XCTAssertTrue(TestHost.isThisProcess)
    }
}
