import Foundation
import AgentPetCore

/// Owns the live session state inside the running app: starts the socket
/// server, drains any queued events on launch, applies incoming events and
/// prunes stale ones, and publishes a display-ordered list to the UI.
///
/// All `SessionStore` access is confined to the main actor.
@MainActor
final class AppDaemon: ObservableObject {
    static let shared = AppDaemon()

    @Published private(set) var sessions: [AgentSession] = []

    private let store: SessionStore = {
        let s = SessionStore()
        s.archiveStore = SessionArchiveStore.shared
        return s
    }()
    private let server = EventSocketServer(path: AgentPetPaths.socketPath)
    private var pruneTimer: Timer?

    /// sessionId → Ghostty surface id. Ghostty exposes no tty or env var that
    /// ties an agent to its terminal, so we bind them on the session's first
    /// events (see `bindGhosttyTerminal`) and look the surface up on click.
    private var ghosttyTerminals: [String: String] = [:]
    private var ghosttyBindAttempts: [String: Int] = [:]
    private static let maxGhosttyBindAttempts = 3

    func start() {
        // The approval reply can race the CLI closing its socket — a stray
        // write must return EPIPE, not SIGPIPE-kill the whole app.
        signal(SIGPIPE, SIG_IGN)
        try? FileManager.default.createDirectory(
            atPath: AgentPetPaths.baseDir, withIntermediateDirectories: true
        )

        // Replay queued events with their original timestamps (not "now"), so
        // sessions that ended while the app was closed look stale and get
        // pruned immediately instead of resurrecting as "working".
        EventSocketServer.drainQueue(directory: AgentPetPaths.queueDir) { [store] event in
            store.apply(event, now: event.timestamp)
        }
        store.prune(now: Date())
        refresh()

        try? server.start { event in
            Task { @MainActor [weak self] in self?.ingest(event) }
        }

        pruneTimer = Timer.scheduledTimer(withTimeInterval: 10, repeats: true) { _ in
            Task { @MainActor [weak self] in self?.prune() }
        }
        ReactiveEngine.shared.start()
    }

    /// Clears the tracked sessions (e.g. after disconnecting an integration).
    func clearSessions() {
        store.clear()
        refresh()
    }

    /// Dismisses a single session (e.g. a stuck agent).
    func removeSession(_ id: String) {
        store.remove(id: id)
        refresh()
    }

    /// Resolves a pending approval from the bubble UI: writes the decision to
    /// the hook and optimistically clears the pending state in the store.
    func resolveApproval(sessionId: String, requestId: String, decision: ApprovalDecision) {
        _ = PendingApprovalRegistry.shared.resolve(requestId: requestId, decision: decision)
        if store.resolveApproval(id: sessionId, requestId: requestId) {
            refresh()
        }
    }

    /// Brings the terminal running `sessionId` to the front (Terminal.app and
    /// iTerm2 focus the exact tab via tty, Ghostty the surface bound to the
    /// session; Warp/others just activate the app).
    func focusTerminal(sessionId: String) {
        guard let session = store.session(id: sessionId) else { return }
        let focus: @MainActor @Sendable () -> Void = { [weak self] in
            guard let self else { return }
            GhosttyLocator.log("click session=\(sessionId.prefix(8)) program=\(session.terminalProgram ?? "nil") "
                + "tty=\(session.terminalTTY ?? "nil") bound=\(self.ghosttyTerminals[sessionId].map { String($0.prefix(8)) } ?? "nil")")
            TerminalFocus.focus(
                program: session.terminalProgram, tty: session.terminalTTY, focusURL: session.terminalFocusURL,
                ghosttyTerminalID: self.ghosttyTerminals[sessionId], project: session.project)
        }
        // No binding yet (the session predates this app run and has been quiet
        // since): resolve it now. The focused surface is where the *user* is, not
        // where the agent is, so only a unique match or the tty probe counts here.
        if session.terminalProgram == "ghostty", ghosttyTerminals[sessionId] == nil {
            bindGhosttyTerminal(for: session, trustFocus: false, ignoreAttemptLimit: true, then: focus)
        } else {
            focus()
        }
    }

    /// Ties `session` to the Ghostty surface it runs in: among the surfaces in the
    /// session's directory that no other session owns, a single one is the answer;
    /// with several, the one whose title changes when we write to the session's
    /// tty, else the focused one, else the first. Runs off
    /// the main thread; a miss is retried on the next few events, then dropped
    /// (clicks then fall back to matching by directory).
    private func bindGhosttyTerminal(
        for session: AgentSession, trustFocus: Bool = true, ignoreAttemptLimit: Bool = false,
        then completion: (@MainActor () -> Void)? = nil
    ) {
        guard session.terminalProgram == "ghostty", let project = session.project,
              ghosttyTerminals[session.id] == nil,
              ignoreAttemptLimit || ghosttyBindAttempts[session.id, default: 0] < Self.maxGhosttyBindAttempts
        else { completion?(); return }
        ghosttyBindAttempts[session.id, default: 0] += 1
        let sessionId = session.id
        let claimed = Set(ghosttyTerminals.values)
        let tty = session.terminalTTY
        Task.detached(priority: .utility) { [weak self] in
            let terminals = GhosttyLocator.listTerminals()
            let candidates = GhosttyTerminalMatcher.candidates(
                project: project, among: terminals, claimed: claimed)
            // Several surfaces in one directory: the path can't tell them apart,
            // so ask the session's own tty which one it is.
            let probed = (candidates.count > 1 ? tty : nil)
                .flatMap { GhosttyLocator.probe(tty: $0, among: candidates) }
            let found = probed
                ?? (candidates.count == 1 || trustFocus
                    ? GhosttyTerminalMatcher.pick(project: project, among: terminals, claimed: claimed)
                    : nil)
            GhosttyLocator.log("bind session=\(sessionId.prefix(8)) project=\(project) tty=\(tty ?? "nil") "
                + "candidates=\(candidates.map { "\($0.id.prefix(8))[\($0.name)]" }) "
                + "probed=\(probed.map { String($0.prefix(8)) } ?? "nil") chosen=\(found.map { String($0.prefix(8)) } ?? "nil")")
            await MainActor.run { [weak self] in
                if let self, let found, self.ghosttyTerminals[sessionId] == nil,
                   !self.ghosttyTerminals.values.contains(found) {
                    self.ghosttyTerminals[sessionId] = found
                }
                completion?()
            }
        }
    }

    private func ingest(_ event: AgentEvent) {
        let before = store.session(id: event.sessionId)?.state
        guard let updated = store.apply(event, now: Date()) else {
            feedSubagentTokens(for: event)
            refresh()
            return
        }
        bindGhosttyTerminal(for: updated)
        resolveTitle(for: event)
        resolveModel(for: event)
        feedLiveTokens(for: event)

        // Claude's Stop hook fires identically whether the agent is truly
        // done or just ended its turn by asking the user a question — hold
        // the notification until an async transcript check resolves, so we
        // fire exactly one notification reflecting the true final state.
        if event.agentKind == .claude, event.eventName == "Stop", updated.state == .done {
            refineDoneIfQuestion(event: event, before: before, session: updated)
        } else {
            notifyIfNeeded(before: before, session: updated)
        }
        refresh()
    }

    /// Resolves which pet should receive XP for a given project path.
    /// Split ON  → the project's configured pet (or the selected pet if unconfigured).
    /// Split OFF → always the selected pet (identical to today's behaviour).
    func careTarget(forProject project: String?) -> String? {
        guard PetController.shared.splitPet else { return PetController.shared.selectedPetID }
        return ProjectPetSettings.shared.petID(forProject: project)
            ?? PetController.shared.selectedPetID
    }

    /// Tokens appear in the transcript while Claude is still working, so the
    /// pet eats live on tool events instead of waiting for `Stop`. Throttled
    /// per session; reads are incremental (offset-based), so the `Stop` path
    /// picking up the remainder never double-counts.
    private var lastLiveFeed: [String: Date] = [:]
    private var codexPathBySession: [String: String] = [:]
    private static let liveFeedInterval: TimeInterval = 10

    private func feedLiveTokens(for event: AgentEvent) {
        switch event.agentKind {
        case .claude:
            // Claude's Stop is handled by refineDoneIfQuestion (it feeds the remainder).
            guard event.eventName != "Stop" else { return }
            let path: String? = event.transcriptPath
                ?? event.project.map { TranscriptReader.inferredPath(sessionId: event.sessionId, cwd: $0) }
            guard let path else { return }
            let now = Date()
            if let last = lastLiveFeed[event.sessionId],
               now.timeIntervalSince(last) < Self.liveFeedInterval { return }
            lastLiveFeed[event.sessionId] = now
            let project = event.project
            Task.detached(priority: .utility) {
                guard let delta = TranscriptReader.newUsageDelta(at: path), delta.tokens > 0 else { return }
                await MainActor.run {
                    PetCareController.shared.feedTokens(delta.tokens,
                        petID: AppDaemon.shared.careTarget(forProject: project))
                    ProjectUsageStore.shared.recordTokens(delta.tokens, project: project, agent: "claude", costUSD: delta.costUSD)
                }
            }
        case .codex:
            feedCodexTokens(for: event)
        default:
            return
        }
    }

    private func feedSubagentTokens(for event: AgentEvent) {
        guard event.eventName == "SubagentStop" || event.eventName == "subagentStop" else { return }
        guard event.agentKind == .claude || event.agentKind == .droid else { return }
        guard let agentId = event.subagentId else { return }
        let parentPath = event.transcriptPath
            ?? event.project.map { TranscriptReader.inferredPath(sessionId: event.sessionId, cwd: $0) }
        guard let parentPath else { return }
        let path = TranscriptReader.subagentTranscriptPath(parentTranscriptPath: parentPath, agentId: agentId)
        let project = event.project
        let agent = event.agentKind.rawValue
        Task.detached(priority: .utility) {
            guard let delta = TranscriptReader.newUsageDelta(at: path), delta.tokens > 0 else { return }
            await MainActor.run {
                PetCareController.shared.feedTokens(delta.tokens,
                    petID: AppDaemon.shared.careTarget(forProject: project))
                ProjectUsageStore.shared.recordTokens(delta.tokens, project: project, agent: agent, costUSD: delta.costUSD)
            }
        }
    }

    /// Codex has no Claude-style transcript; it writes a rollout JSONL under
    /// ~/.codex/sessions with per-turn token counts. Feed those so Codex earns
    /// token-based XP like Claude (#29). Feeds live on tool events and once more
    /// on Stop to catch the final turn; reads are incremental so no double-count.
    private func feedCodexTokens(for event: AgentEvent) {
        let isStop = event.eventName == "Stop"
        let now = Date()
        if !isStop, let last = lastLiveFeed[event.sessionId],
           now.timeIntervalSince(last) < Self.liveFeedInterval { return }
        lastLiveFeed[event.sessionId] = now
        let sid = event.sessionId
        let project = event.project
        let cachedPath = codexPathBySession[sid]
        Task.detached(priority: .utility) {
            guard let path = cachedPath
                ?? TranscriptReader.codexRolloutPath(sessionId: sid, cwd: project) else { return }
            let tokens = TranscriptReader.newCodexUsageTokens(at: path) ?? 0
            await MainActor.run {
                AppDaemon.shared.codexPathBySession[sid] = path
                guard tokens > 0 else { return }
                PetCareController.shared.feedTokens(tokens,
                    petID: AppDaemon.shared.careTarget(forProject: project))
                ProjectUsageStore.shared.recordTokens(tokens, project: project, agent: "codex")
            }
        }
    }

    /// Reads the transcript off-thread to check whether Claude ended its turn
    /// by asking the user something; if so, corrects `.done` to `.waiting`.
    /// Either way, fires the (single, final-state) notification afterwards.
    private func refineDoneIfQuestion(event: AgentEvent, before: AgentState?, session: AgentSession) {
        let sessionId = event.sessionId
        let stateSince = session.stateSince
        let path: String? = event.transcriptPath
            ?? event.project.map { TranscriptReader.inferredPath(sessionId: sessionId, cwd: $0) }
        guard let path else {
            notifyIfNeeded(before: before, session: session)
            return
        }
        // Capture the project string (Sendable) before crossing the actor boundary.
        let project = session.project
        Task.detached(priority: .utility) { [weak self] in
            let isQuestion = TranscriptReader.latestAssistantText(at: path)
                .map(QuestionDetector.looksLikeQuestion) ?? false
            // The turn just ended either way — feed the pet the tokens it burnt.
            let delta = TranscriptReader.newUsageDelta(at: path)
            await MainActor.run { [weak self] in
                guard let self else { return }
                PetCareController.shared.feedTokens(delta?.tokens ?? 0,
                    petID: self.careTarget(forProject: project))
                ProjectUsageStore.shared.recordTokens(delta?.tokens ?? 0, project: project, agent: "claude", costUSD: delta?.costUSD ?? 0)
                if isQuestion {
                    self.store.refineState(id: sessionId, from: .done, to: .waiting, since: stateSince)
                }
                guard let final = self.store.session(id: sessionId) else { return }
                self.notifyIfNeeded(before: before, session: final)
                self.refresh()
            }
        }
    }

    private func resolveTitle(for event: AgentEvent) {
        // A title, once resolved, is stable — stop re-reading the transcript
        // head on every subsequent event. Without this the transcript was
        // re-read and re-parsed on every hook event of a session.
        guard store.session(id: event.sessionId)?.title == nil else { return }
        let sessionId = event.sessionId
        let path: String? = event.transcriptPath
            ?? event.project.map { TranscriptReader.inferredPath(sessionId: sessionId, cwd: $0) }
        guard let path else { return }
        Task.detached(priority: .utility) { [weak self] in
            guard let title = TranscriptReader.title(at: path) else { return }
            await MainActor.run { [weak self] in
                self?.store.updateTitle(id: sessionId, title: title)
                self?.refresh()
            }
        }
    }

    /// Reads the transcript off-thread for the model of the latest assistant
    /// message — picks up `/model` switches mid-session, which Claude's hook
    /// payloads only report at `SessionStart`.
    /// Reading the transcript tail to detect a `/model` switch is the heaviest
    /// per-event work (128 KB read + JSON parse per line). The model rarely
    /// changes mid-session and its initial value already comes from the hook
    /// payload, so throttle this hard rather than running it on every event.
    private let modelResolveThrottle = PerKeyThrottle(interval: 30)

    private func resolveModel(for event: AgentEvent) {
        guard event.agentKind == .claude else { return }
        guard modelResolveThrottle.shouldRun(event.sessionId, now: Date()) else { return }
        let sessionId = event.sessionId
        let path: String? = event.transcriptPath
            ?? event.project.map { TranscriptReader.inferredPath(sessionId: sessionId, cwd: $0) }
        guard let path else { return }
        Task.detached(priority: .utility) { [weak self] in
            guard let model = TranscriptReader.latestAssistantModel(at: path) else { return }
            await MainActor.run { [weak self] in
                self?.store.updateModel(id: sessionId, model: model)
                self?.refresh()
            }
        }
    }

    private func notifyIfNeeded(before: AgentState?, session: AgentSession) {
        guard session.state != before else { return }
        let project = session.project.map { ($0 as NSString).lastPathComponent } ?? session.id
        switch session.state {
        case .waiting:
            NotificationManager.shared.notify(
                title: "\(project) needs input", body: session.message ?? "Waiting for you",
                sessionId: session.id)
            SoundSettings.shared.play(.waiting)
        case .done:
            NotificationManager.shared.notify(
                title: "\(project) finished", body: "Agent completed its turn",
                sessionId: session.id)
            SoundSettings.shared.play(.done)
            PetCareController.shared.recordMeal(petID: careTarget(forProject: session.project))
            ProjectUsageStore.shared.recordSession(project: session.project, agent: session.agentKind.rawValue)
        default:
            break
        }
    }

    private func prune() {
        store.prune(now: Date())
        guard store.sorted != sessions else { return }
        refresh()
    }

    private func refresh() {
        sessions = store.sorted
        // Drop bindings for sessions that were removed, cleared or pruned.
        let live = Set(sessions.map(\.id))
        ghosttyTerminals = ghosttyTerminals.filter { live.contains($0.key) }
        ghosttyBindAttempts = ghosttyBindAttempts.filter { live.contains($0.key) }
        PetController.shared.update(sessions: sessions)
        StatusBarController.shared.updateStatus(sessions)
    }
}
