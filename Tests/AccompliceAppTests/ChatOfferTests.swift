import XCTest
@testable import Accomplice

/// Offers to spend money, and which one a press belongs to.
@MainActor
final class ChatOfferTests: XCTestCase {

    private func session(withNotes n: Int) -> ChatSession {
        let s = ChatSession()
        for i in 0..<n { s.messages.append(ChatMessage(role: .assistant, text: "note \(i)")) }
        return s
    }

    /// The bug: after a couple of goes the transcript holds several offers, and
    /// clearing "the first message that has one" put an old one away and left
    /// the button just pressed sitting there asking to be pressed again.
    func testPressingAnOfferClearsThatOneAndNotAnOlderOne() {
        let s = session(withNotes: 1)
        var firstRan = false, secondRan = false
        s.offerPaidRemove(label: "First") { firstRan = true }
        let firstMessage = s.messages.last!.id

        s.messages.append(ChatMessage(role: .assistant, text: "another activity"))
        s.offerPaidRemove(label: "Second") { secondRan = true }
        let secondMessage = s.messages.last!.id

        XCTAssertNotNil(s.messages.first(where: { $0.id == firstMessage })?.offer)
        s.messages.first(where: { $0.id == secondMessage })?.offer?.run()

        XCTAssertTrue(secondRan, "the offer that was pressed should be the one that runs")
        XCTAssertFalse(firstRan)
        XCTAssertNil(s.messages.first(where: { $0.id == secondMessage })?.offer,
                     "the offer that was pressed has to go, or it invites a second charge")
        XCTAssertNotNil(s.messages.first(where: { $0.id == firstMessage })?.offer,
                        "an older offer is not the one that was taken")
    }

    func testDecliningPutsOnlyThatOfferAway() {
        let s = session(withNotes: 1)
        s.offerPaidRemove(label: "First") { }
        let first = s.messages.last!.id
        s.messages.append(ChatMessage(role: .assistant, text: "later"))
        s.offerPaidRemove(label: "Second") { }
        let second = s.messages.last!.id

        s.declineOffer(second)
        XCTAssertNil(s.messages.first(where: { $0.id == second })?.offer)
        XCTAssertNotNil(s.messages.first(where: { $0.id == first })?.offer)
    }
}
