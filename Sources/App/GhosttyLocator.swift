import AppKit
import AgentPetCore
import Foundation

/// Talks to Ghostty over AppleScript: lists its terminal surfaces so a session
/// can be bound to one, and focuses a surface by id.
enum GhosttyLocator {
    static let bundleID = "com.mitchellh.ghostty"

    /// `tell application` would launch Ghostty if it isn't running; never do that.
    static var isRunning: Bool {
        !NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).isEmpty
    }

    /// Blocking (spawns osascript) — call off the main thread.
    static func listTerminals() -> [GhosttyTerminal] {
        guard isRunning, let out = runScript(listScript) else { return [] }
        return out.split(separator: "\n").compactMap { line in
            let f = line.split(separator: "\t", omittingEmptySubsequences: false)
            guard f.count == 3 else { return nil }
            return GhosttyTerminal(id: String(f[0]), workingDirectory: String(f[1]), isFocused: f[2] == "1")
        }
    }

    /// Focuses the surface with `id` (selecting its tab and restoring its window
    /// if minimized). When the id is unknown or stale, falls back to a surface
    /// in `project`, and finally to just activating the app.
    static func focusScript(terminalID: String?, project: String?) -> String {
        var body = ""
        if let terminalID {
            body += """
                try
                    focus terminal id "\(escape(terminalID))"
                    return
                end try

            """
        }
        if let project {
            let p = GhosttyTerminalMatcher.normalize(project)
            body += """
                repeat with t in terminals
                    try
                        set d to working directory of t
                        if d is "\(escape(p))" or d is "\(escape(p))/" then
                            focus t
                            return
                        end if
                    end try
                end repeat

            """
        }
        return """
        tell application id "\(bundleID)"
        \(body)    activate
        end tell
        """
    }

    // Only the front window's selected tab has a meaningful focused surface, and
    // only while Ghostty is the active app.
    private static let listScript = """
        tell application id "\(bundleID)"
            set fid to ""
            try
                if frontmost then set fid to id of focused terminal of selected tab of front window
            end try
            set out to ""
            repeat with t in terminals
                set flag to "0"
                if (id of t) is fid then set flag to "1"
                set out to out & (id of t) & tab & (working directory of t) & tab & flag & linefeed
            end repeat
            return out
        end tell
        """

    private static func escape(_ s: String) -> String {
        s.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"")
    }

    private static func runScript(_ source: String) -> String? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        process.arguments = ["-e", source]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        guard (try? process.run()) != nil else { return nil }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else { return nil }
        return String(decoding: data, as: UTF8.self)
    }
}
