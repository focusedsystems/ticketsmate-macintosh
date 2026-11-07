import XCTest
@testable import TicketsMateCore

final class TicketsMateLinkTests: XCTestCase {
    private func parse(_ s: String) throws -> TicketsMateLink { try TicketsMateLink.parse(URL(string: s)!) }






    func testTicketsMateLinksOnlyOpenTickets() throws {
        XCTAssertEqual(try parse("ticketsmate://ticket/1234567"), .ticket(id: 1234567))
        XCTAssertEqual(AppEdition.ticketsMate.linkScheme, "ticketsmate")
        XCTAssertEqual(AppEdition.ticketsMate.linkScheme, "ticketsmate")
        for value in ["ticketsmate://ticket/0", "ticketsmate://ticket/-1", "ticketsmate://ticket/2147483648",
                      "ticketsmate://ticket/1/extra", "ticketsmate://ticket/%31", "ticketsmate://ticket/1?x=2",
                      "ticketsmate://ticket/1#feed", "ticketsmate://user@ticket/1", "ticketsmate://ticket:9/1",
                      "ticketsmate://device/1", "ticketsmate://open?url=https://example.com"] {
            XCTAssertThrowsError(try parse(value), value)
        }
    }



    /// Names reach API paths, so a link can't smuggle in path segments.
}
