import XCTest
@testable import TicketsMateCore

final class TicketBrowserUrlTests: XCTestCase {
    func testExplicitBrowserLinkBypassesHandoffWhileSharedLinkStaysUnmarked() {
        var config = TicketsMateConfig()
        config.tdxBaseUrl = "https://support.example.invalid/TDWebApi"
        config.tdxAppId = 31
        config.tdxTicketingAppId = 44
        let shared = "https://support.example.invalid/TDNext/Apps/44/Tickets/TicketDet?TicketID=12345"
        XCTAssertEqual(config.tdxTicketWebUrl(12345), shared)
        XCTAssertEqual(config.tdxTicketBrowserUrl(12345), shared + "&ticketsmate=browser")
    }
}
