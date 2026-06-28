import Foundation

public enum RawExecutableLaunchGuard {
    public static func redirectIfNeeded() {
        let executablePath = currentExecutablePath()
        let currentDirectory = FileManager.default.currentDirectoryPath
        let bundleIdentifier = Bundle.main.bundleIdentifier

        guard shouldRedirect(
            executablePath: executablePath,
            currentDirectory: currentDirectory,
            bundleIdentifier: bundleIdentifier
        ) else {
            return
        }

        let appBundlePath = configuredAppBundlePath()
        warn("cmux-project-launcher was opened from the SwiftPM build directory.")
        warn("Opening \(appBundlePath) instead.")

        if FileManager.default.fileExists(atPath: appBundlePath) {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/open")
            process.arguments = [appBundlePath]
            do {
                try process.run()
                process.waitUntilExit()
                if process.terminationStatus != 0 {
                    warn("open exited with status \(process.terminationStatus).")
                }
            } catch {
                warn("Could not open app bundle: \(error.localizedDescription)")
            }
        } else {
            warn("App bundle not found. Build it with: bin/build-app-bundle")
        }

        Foundation.exit(0)
    }

    public static func shouldRedirect(
        executablePath: String,
        currentDirectory: String,
        bundleIdentifier: String?
    ) -> Bool {
        if let bundleIdentifier, !bundleIdentifier.isEmpty {
            return false
        }

        let executableURL = URL(fileURLWithPath: executablePath).standardizedFileURL
        let executable = executableURL.path
        guard executable.hasSuffix("/cmux-project-launcher"),
              executable.contains("/.build/") else {
            return false
        }

        let executableDirectory = executableURL.deletingLastPathComponent().path
        let cwd = URL(fileURLWithPath: currentDirectory).standardizedFileURL.path
        return cwd == executableDirectory
    }

    private static func currentExecutablePath() -> String {
        if let executableURL = Bundle.main.executableURL {
            return executableURL.path
        }

        let argument = CommandLine.arguments.first ?? "cmux-project-launcher"
        if argument.hasPrefix("/") {
            return argument
        }
        return URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
            .appendingPathComponent(argument)
            .standardizedFileURL
            .path
    }

    private static func configuredAppBundlePath() -> String {
        if let override = ProcessInfo.processInfo.environment["CMUX_PROJECT_LAUNCHER_APP_BUNDLE"],
           !override.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return NSString(string: override).expandingTildeInPath
        }
        return NSHomeDirectory() + "/Applications/CmuxProjectLauncher.app"
    }

    private static func warn(_ message: String) {
        FileHandle.standardError.write(Data((message + "\n").utf8))
    }
}
