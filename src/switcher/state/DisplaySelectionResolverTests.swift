import XCTest

final class DisplaySelectionResolverTests: XCTestCase {
    func testConnectedSelectionWins() {
        XCTAssertEqual(DisplaySelectionResolver.preferredUuid("studio", ["built-in", "studio"], "built-in"), "studio")
    }

    func testDisconnectedSelectionUsesConnectedFallback() {
        XCTAssertEqual(DisplaySelectionResolver.preferredUuid("studio", ["built-in", "projector"], "projector"), "projector")
    }

    func testUnavailableFallbackUsesFirstConnectedDisplay() {
        XCTAssertEqual(DisplaySelectionResolver.preferredUuid("studio", ["built-in", "projector"], "missing"), "built-in")
    }

    func testNoConnectedDisplayReturnsNil() {
        XCTAssertNil(DisplaySelectionResolver.preferredUuid("studio", [], "built-in"))
    }
}
