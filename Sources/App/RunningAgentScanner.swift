import AgentPetCore
import Darwin
import Foundation

/// Finds Claude Code sessions that were already open when AgentPet launched.
/// Hooks only report on the next event, so an idle agent opened earlier would
/// otherwise stay invisible (and unfocusable) until it did something.
///
/// Claude Code writes `~/.claude/sessions/<pid>.json` (session id, cwd, pid) for
/// every live session; we keep the interactive CLI ones whose process is alive,
/// and read the tty and hosting terminal from the process itself.
enum RunningAgentScanner {
    private struct SessionFile: Decodable {
        let pid: Int32
        let sessionId: String
        let cwd: String
        let kind: String?
        let entrypoint: String?
    }

    /// Blocking (spawns `ps`) — call off the main thread.
    static func claudeSessions(now: Date = Date()) -> [AgentEvent] {
        let dir = NSHomeDirectory() + "/.claude/sessions"
        guard let names = try? FileManager.default.contentsOfDirectory(atPath: dir) else { return [] }
        return names.filter { $0.hasSuffix(".json") }.compactMap { name in
            guard let data = FileManager.default.contents(atPath: dir + "/" + name),
                  let file = try? JSONDecoder().decode(SessionFile.self, from: data),
                  file.kind == "interactive", file.entrypoint == "cli",
                  isClaudeProcess(file.pid)
            else { return nil }
            let tty = ps(["-o", "tty=", "-p", String(file.pid)]).trimmingCharacters(in: .whitespacesAndNewlines)
            return AgentEvent(
                sessionId: file.sessionId, agentKind: .claude, eventName: "SessionStart",
                project: file.cwd,
                terminalProgram: terminalProgram(ofPID: file.pid),
                terminalTTY: tty.isEmpty || tty == "??" ? nil : "/dev/" + tty,
                timestamp: now)
        }
    }

    /// Guards against a stale file whose pid was reused by another process.
    private static func isClaudeProcess(_ pid: Int32) -> Bool {
        guard kill(pid, 0) == 0 else { return false }
        return ps(["-o", "comm=", "-p", String(pid)]).contains("claude")
    }

    /// `TERM_PROGRAM` isn't readable from another process, so walk up the parents
    /// until one is a known terminal app.
    private static func terminalProgram(ofPID start: Int32) -> String? {
        let known: [(marker: String, program: String)] = [
            ("/Ghostty.app/", "ghostty"), ("/iTerm.app/", "iTerm.app"),
            ("/Terminal.app/", "Apple_Terminal"), ("/Warp.app/", "WarpTerminal"),
        ]
        var pid = start
        for _ in 0..<12 where pid > 1 {
            let fields = ps(["-o", "ppid=,comm=", "-p", String(pid)])
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .split(separator: " ", maxSplits: 1)
            guard fields.count == 2, let parent = Int32(fields[0]) else { return nil }
            if let hit = known.first(where: { fields[1].contains($0.marker) }) { return hit.program }
            pid = parent
        }
        return nil
    }

    private static func ps(_ args: [String]) -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/ps")
        process.arguments = args
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        guard (try? process.run()) != nil else { return "" }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return String(decoding: data, as: UTF8.self)
    }
}
