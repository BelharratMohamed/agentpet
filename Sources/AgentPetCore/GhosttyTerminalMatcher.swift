import Foundation

/// A Ghostty terminal surface as reported by its AppleScript dictionary.
/// Ghostty exposes neither the tty nor an env var holding this id, so the only
/// way to tie an agent to its surface is to match on what it does expose.
public struct GhosttyTerminal: Sendable, Equatable {
    public let id: String
    public let workingDirectory: String
    /// True only for the focused surface of the front window while Ghostty is
    /// the active app — i.e. the one the user is typing into right now.
    public let isFocused: Bool

    public init(id: String, workingDirectory: String, isFocused: Bool) {
        self.id = id
        self.workingDirectory = workingDirectory
        self.isFocused = isFocused
    }
}

public enum GhosttyTerminalMatcher {
    /// Picks the surface running an agent whose project is `project`.
    ///
    /// Candidates are the terminals sitting in that directory that no other
    /// session has claimed yet. With a single candidate that's the answer; with
    /// several, the focused one wins (an agent is nearly always launched from the
    /// terminal the user is typing in), otherwise the first. `nil` when nothing
    /// matches, so the caller can retry on a later event.
    public static func pick(
        project: String,
        among terminals: [GhosttyTerminal],
        claimed: Set<String>
    ) -> String? {
        let target = normalize(project)
        let candidates = terminals.filter {
            !claimed.contains($0.id) && normalize($0.workingDirectory) == target
        }
        return (candidates.first(where: \.isFocused) ?? candidates.first)?.id
    }

    /// Ghostty reports directories with a trailing slash on some surfaces and not
    /// on others; compare them without it.
    public static func normalize(_ path: String) -> String {
        var p = path
        while p.count > 1, p.hasSuffix("/") { p.removeLast() }
        return p
    }
}
