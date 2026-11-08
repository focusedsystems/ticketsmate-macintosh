import XCTest
@testable import TicketsMateCore

final class AppEditionTests: XCTestCase {
    func testStandaloneBuildIsTicketsMate() {
        XCTAssertEqual(AppEdition.current, .ticketsMate)
        XCTAssertTrue(AppEdition.current.isTicketsOnly)
        XCTAssertEqual(AppEdition.current.linkScheme, "ticketsmate")
    }

    func testSettingsAndLogsLiveUnderTicketsMate() {
        XCTAssertEqual(AppEdition.ticketsMate.supportDirectory, "~/.ticketsmate")
        XCTAssertTrue(AppEdition.ticketsMate.supportPath("config.yaml").hasSuffix("/.ticketsmate/config.yaml"))
        XCTAssertEqual(AppEdition.ticketsMate.logDirectory, "~/Library/Logs/TicketsMate")
    }

    func testDomainIsTheBundleIdentifier() {
        XCTAssertEqual(AppEdition.ticketsMate.preferencesDomain(bundleIdentifier: "example.ticketsmate"), "example.ticketsmate")
        XCTAssertEqual(AppEdition.ticketsMate.preferencesDomain(bundleIdentifier: nil), AppEdition.defaultBundleIdentifier)
    }
}
