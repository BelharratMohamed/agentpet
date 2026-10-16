import XCTest
@testable import AgentPetCore

final class GhosttyTerminalMatcherTests: XCTestCase {
    private func term(_ id: String, _ dir: String, focused: Bool = false) -> GhosttyTerminal {
        GhosttyTerminal(id: id, workingDirectory: dir, isFocused: focused)
    }

    func testSingleMatchWins() {
        let all = [term("a", "/p/one"), term("b", "/p/two")]
        XCTAssertEqual(GhosttyTerminalMatcher.pick(project: "/p/two", among: all, claimed: []), "b")
    }

    func testTrailingSlashIsIgnoredOnBothSides() {
        let all = [term("a", "/p/one/")]
        XCTAssertEqual(GhosttyTerminalMatcher.pick(project: "/p/one", among: all, claimed: []), "a")
        XCTAssertEqual(GhosttyTerminalMatcher.pick(project: "/p/one/", among: [term("a", "/p/one")], claimed: []), "a")
    }

    func testNoMatchReturnsNil() {
        XCTAssertNil(GhosttyTerminalMatcher.pick(project: "/p/x", among: [term("a", "/p/one")], claimed: []))
    }

    func testClaimedTerminalsAreSkipped() {
        let all = [term("a", "/p"), term("b", "/p")]
        XCTAssertEqual(GhosttyTerminalMatcher.pick(project: "/p", among: all, claimed: ["a"]), "b")
        XCTAssertNil(GhosttyTerminalMatcher.pick(project: "/p", among: all, claimed: ["a", "b"]))
    }

    func testFocusedBreaksTieBetweenSameDirectory() {
        let all = [term("a", "/p"), term("b", "/p", focused: true)]
        XCTAssertEqual(GhosttyTerminalMatcher.pick(project: "/p", among: all, claimed: []), "b")
    }

    func testFirstWinsWhenNothingIsFocused() {
        let all = [term("a", "/p"), term("b", "/p")]
        XCTAssertEqual(GhosttyTerminalMatcher.pick(project: "/p", among: all, claimed: []), "a")
    }

    func testRootIsNotStrippedToEmpty() {
        XCTAssertEqual(GhosttyTerminalMatcher.pick(project: "/", among: [term("a", "/")], claimed: []), "a")
    }
}
