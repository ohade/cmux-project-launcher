import Testing
@testable import CmuxProjectLauncherCore

struct RawExecutableLaunchGuardTests {
    @Test func redirectsRawBuildExecutableOpenedFromItsDirectory() {
        let executable = "/Users/example/git/playground/cmux-project-launcher/.build/arm64-apple-macosx/debug/cmux-project-launcher"
        let cwd = "/Users/example/git/playground/cmux-project-launcher/.build/arm64-apple-macosx/debug"

        #expect(RawExecutableLaunchGuard.shouldRedirect(
            executablePath: executable,
            currentDirectory: cwd,
            bundleIdentifier: nil
        ))
    }

    @Test func doesNotRedirectAppBundleLaunch() {
        let executable = "/Users/example/Applications/CmuxProjectLauncher.app/Contents/MacOS/cmux-project-launcher"
        let cwd = "/Users/example"

        #expect(!RawExecutableLaunchGuard.shouldRedirect(
            executablePath: executable,
            currentDirectory: cwd,
            bundleIdentifier: "com.ohad.cmux-project-launcher"
        ))
    }

    @Test func doesNotRedirectSwiftRunFromRepoRoot() {
        let executable = "/Users/example/git/playground/cmux-project-launcher/.build/arm64-apple-macosx/debug/cmux-project-launcher"
        let cwd = "/Users/example/git/playground/cmux-project-launcher"

        #expect(!RawExecutableLaunchGuard.shouldRedirect(
            executablePath: executable,
            currentDirectory: cwd,
            bundleIdentifier: nil
        ))
    }

    @Test func doesNotRedirectOtherBuildExecutable() {
        let executable = "/Users/example/git/playground/cmux-project-launcher/.build/arm64-apple-macosx/debug/other-tool"
        let cwd = "/Users/example/git/playground/cmux-project-launcher/.build/arm64-apple-macosx/debug"

        #expect(!RawExecutableLaunchGuard.shouldRedirect(
            executablePath: executable,
            currentDirectory: cwd,
            bundleIdentifier: nil
        ))
    }
}
