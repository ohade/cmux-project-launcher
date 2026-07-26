import XCTest
@testable import CmuxProjectLauncherCore

/// Regression coverage for the launcher hanging forever after a successful launch.
///
/// `cmux-project-launch` registers long-lived `amq wake` daemons that inherit the launcher's
/// captured pipe write ends and outlive the script. `run()` used to finish by reading each pipe
/// to end-of-file, which only arrives once *every* writer closes — so the call never returned,
/// `creatingAdHocWorkspace` was never cleared, and the Ad-hoc spinner spun indefinitely.
final class ProcessPipeDrainTests: XCTestCase {
    private func makeScript(_ body: String) throws -> String {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("cmux-drain-test-\(UUID().uuidString).sh")
        try ("#!/bin/sh\n" + body + "\n").write(to: url, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
        return url.path
    }

    /// A child that leaves a daemon holding the inherited pipes must not block `run()`.
    func testReturnsWhenChildLeavesDaemonHoldingInheritedPipes() throws {
        // The background `sleep` inherits stdout and stderr and keeps the write ends open well
        // past the script's own exit, exactly like the registered wake daemons.
        let script = try makeScript("sleep 45 & echo launched-ok")
        let launcher = CmuxLauncher()

        var output: String?
        let finished = expectation(description: "run() returned without waiting for end-of-file")
        DispatchQueue.global().async {
            output = try? launcher.run(executablePath: script, arguments: [], environment: [:])
            finished.fulfill()
        }

        // Comfortably shorter than the daemon's lifetime and the 300s command timeout, so this
        // only passes if the read stopped depending on the surviving writer.
        wait(for: [finished], timeout: 20)
        XCTAssertEqual(output, "launched-ok")
    }

    /// Normal output must still be captured in full.
    func testCapturesOutputFromOrdinaryCommand() throws {
        let script = try makeScript("echo first; echo second >&2; echo third")
        let launcher = CmuxLauncher()

        let output = try launcher.run(executablePath: script, arguments: [], environment: [:])

        XCTAssertEqual(output, "first\nthird")
    }

    /// A non-zero exit must still surface as a failure rather than being swallowed.
    func testFailingCommandStillThrows() throws {
        let script = try makeScript("echo boom >&2; exit 3")
        let launcher = CmuxLauncher()

        XCTAssertThrowsError(try launcher.run(executablePath: script, arguments: [], environment: [:]))
    }
}
