import XCTest
@testable import TicketsMateApp

/// Rendered text refuses third-party images unless its caller says the source
/// is trusted, so a new caller never loads them by accident.
final class MarkdownTextViewImageTests: XCTestCase {
    private let tdx = URL(string: "https://example.teamdynamix.com/TDWebApi")
    private let thirdParty = URL(string: "https://tracker.example/pixel.gif")!
    private let tdxImage = URL(string: "https://example.teamdynamix.com/TDPortal/image.png")!

    func testDefaultArgumentsRefuseThirdPartyImages() {
        let view = MarkdownTextView(content: "![x](https://tracker.example/pixel.gif)")
        XCTAssertTrue(view.restrictsImages)
        XCTAssertFalse(view.mayLoadImage(thirdParty, tdxBase: tdx, allowExternal: false))
        XCTAssertTrue(view.mayLoadImage(tdxImage, tdxBase: tdx, allowExternal: false))
    }

    func testTheExternalImagesSettingLetsThemThrough() {
        let view = MarkdownTextView(content: "")
        XCTAssertTrue(view.mayLoadImage(thirdParty, tdxBase: tdx, allowExternal: true))
    }

}
