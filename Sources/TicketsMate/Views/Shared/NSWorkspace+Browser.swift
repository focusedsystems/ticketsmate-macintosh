import AppKit
import TicketsMateCore

extension NSWorkspace {
    /// Open a web page in the browser, marked so a managed link extension
    /// does not hand it straight back to TicketsMate.
    @discardableResult
    func openInBrowser(_ url: URL) -> Bool {
        open(BrowserLink.forBrowser(url))
    }
}
