@testable import LemurCam
import XCTest

/// Pins the quit, relaunch, and launch-guard decisions. A relaunch must never stop
/// at the "Camera in Use" prompt, a launch guard must never prompt (Cancel there
/// leaves a UI-less process), and the relauncher must wait for the old process to
/// exit so the new instance doesn't quit itself as a duplicate.
internal final class AppLifecycleDecisionTests: XCTestCase {

    // MARK: - Quit prompt

    func testPromptsOnlyForAFinishedLaunchWithConsumersAndNoRelaunch() {
        XCTAssertEqual(
            TerminationDecision.evaluate(hasFinishedLaunching: true, isRelaunching: false, hasExternalConsumers: true),
            .confirmCameraInUse
        )
    }

    func testQuitsWithoutPromptWhenNoExternalConsumer() {
        XCTAssertEqual(
            TerminationDecision.evaluate(hasFinishedLaunching: true, isRelaunching: false, hasExternalConsumers: false),
            .terminateNow
        )
    }

    func testRelaunchSkipsPromptEvenWithConsumers() {
        XCTAssertEqual(
            TerminationDecision.evaluate(hasFinishedLaunching: true, isRelaunching: true, hasExternalConsumers: true),
            .terminateNow
        )
    }

    func testLaunchGuardQuitSkipsPromptEvenWithConsumers() {
        XCTAssertEqual(
            TerminationDecision.evaluate(hasFinishedLaunching: false, isRelaunching: false, hasExternalConsumers: true),
            .terminateNow
        )
    }

    // MARK: - Duplicate-instance guard

    func testNoOtherInstanceContinuesLaunch() {
        let instances = [RunningInstance(pid: 10, isAlive: true)]
        XCTAssertNil(LaunchGuardDecision.existingInstance(currentPID: 10, instances: instances))
    }

    func testLiveOtherInstanceWins() {
        let instances = [RunningInstance(pid: 10, isAlive: true), RunningInstance(pid: 20, isAlive: true)]
        XCTAssertEqual(LaunchGuardDecision.existingInstance(currentPID: 10, instances: instances), 20)
    }

    func testExitedInstanceStillListedIsIgnored() {
        // The instance that just relaunched us can linger in LaunchServices' list
        // briefly after it exits; it must not make the new instance quit.
        let instances = [RunningInstance(pid: 20, isAlive: false), RunningInstance(pid: 10, isAlive: true)]
        XCTAssertNil(LaunchGuardDecision.existingInstance(currentPID: 10, instances: instances))
    }

    // MARK: - Launch location

    func testApplicationsFolderIsAccepted() {
        XCTAssertNil(LaunchLocationDecision.problem(bundlePath: "/Applications/LemurCam.app"))
    }

    func testOtherLocationsMustMoveToApplications() {
        XCTAssertEqual(
            LaunchLocationDecision.problem(bundlePath: "/Users/someone/Downloads/LemurCam.app"),
            .notInApplications
        )
        XCTAssertEqual(
            LaunchLocationDecision.problem(bundlePath: "/ApplicationsCopy/LemurCam.app"),
            .notInApplications
        )
    }

    func testTranslocatedLaunchIsRecognized() {
        let path = "/private/var/folders/ab/cdef/T/AppTranslocation/0F1E2D3C-4B5A-6978-8796-A5B4C3D2E1F0/d/LemurCam.app"
        XCTAssertEqual(LaunchLocationDecision.problem(bundlePath: path), .translocated)
    }

    func testTranslocationMessageDoesNotOnlySayMoveToApplications() {
        // The translocated copy may already live in /Applications; the fix is a
        // Finder move or clearing quarantine, so the copy must say so.
        let message = LaunchLocationProblem.translocated.alertMessage
        XCTAssertTrue(message.contains("Finder"))
        XCTAssertTrue(message.contains("com.apple.quarantine"))
    }

    // MARK: - Relauncher

    func testRelaunchArgumentsPassValuesPositionally() {
        let path = "/Applications/Lemur \"Cam\".app"
        XCTAssertEqual(
            RelaunchCommand.arguments(waitingFor: 4242, appPath: path),
            ["-c", RelaunchCommand.script, "lemurcam-relaunch", "4242", path, "/usr/bin/open", "100"]
        )
        XCTAssertFalse(RelaunchCommand.script.contains(path))
    }

    func testRelauncherOpensImmediatelyWhenOldProcessIsGone() throws {
        let exited = try runToCompletion("/usr/bin/true")
        let relauncher = try startRelauncher(waitingFor: exited.processIdentifier, maxPolls: 600)
        wait(for: [relauncher.finished], timeout: 10)
        XCTAssertEqual(relauncher.output(), "[-n][\(Self.appPath)]")
    }

    func testRelauncherWaitsForOldProcessToExit() throws {
        let sleeper = try startProcess("/bin/sleep", ["30"])
        defer { if sleeper.isRunning { sleeper.terminate() } }
        let relauncher = try startRelauncher(waitingFor: sleeper.processIdentifier, maxPolls: 600)

        Thread.sleep(forTimeInterval: 0.5)
        XCTAssertTrue(relauncher.process.isRunning, "Must not open the new instance while the old one runs")

        sleeper.terminate()
        sleeper.waitUntilExit()
        wait(for: [relauncher.finished], timeout: 10)
        XCTAssertEqual(relauncher.output(), "[-n][\(Self.appPath)]")
    }

    func testRelauncherWaitIsBounded() throws {
        let sleeper = try startProcess("/bin/sleep", ["30"])
        defer { if sleeper.isRunning { sleeper.terminate() } }
        let relauncher = try startRelauncher(waitingFor: sleeper.processIdentifier, maxPolls: 3)
        wait(for: [relauncher.finished], timeout: 10)
        XCTAssertTrue(sleeper.isRunning)
        XCTAssertEqual(relauncher.output(), "[-n][\(Self.appPath)]")
    }

    // MARK: - Helpers

    /// A bundle path with a space and a quote, to prove it reaches the opener intact.
    private static let appPath = "/tmp/Lemur Cam's Test/LemurCam.app"

    private struct Relauncher {
        let process: Process
        let pipe: Pipe
        let finished: XCTestExpectation

        func output() -> String {
            String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        }
    }

    /// Writes a stand-in for `open` that prints each argument in brackets, so the
    /// test sees exactly what the relauncher would hand to `open`.
    private func makeArgumentPrinter() throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        let printer = directory.appendingPathComponent("print-args")
        try "#!/bin/sh\nprintf '[%s]' \"$@\"\n".write(to: printer, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: printer.path)
        return printer
    }

    /// Runs the real relaunch script with an argument printer standing in for `open`.
    private func startRelauncher(waitingFor pid: pid_t, maxPolls: Int) throws -> Relauncher {
        let opener = try makeArgumentPrinter()
        let finished = expectation(description: "relauncher exited")
        let pipe = Pipe()
        let process = Process()
        process.executableURL = URL(fileURLWithPath: RelaunchCommand.shellPath)
        process.arguments = RelaunchCommand.arguments(
            waitingFor: pid, appPath: Self.appPath, opener: opener.path, maxPolls: maxPolls
        )
        process.standardOutput = pipe
        process.terminationHandler = { _ in finished.fulfill() }
        try process.run()
        return Relauncher(process: process, pipe: pipe, finished: finished)
    }

    private func startProcess(_ path: String, _ arguments: [String]) throws -> Process {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: path)
        process.arguments = arguments
        try process.run()
        return process
    }

    private func runToCompletion(_ path: String) throws -> Process {
        let process = try startProcess(path, [])
        process.waitUntilExit()
        return process
    }
}
