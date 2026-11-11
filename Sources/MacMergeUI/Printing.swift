import AppKit
import WebKit

/// Prints a comparison by laying out its HTML report in an off-screen web view.
@MainActor
final class ReportPrinter: NSObject, WKNavigationDelegate {
    private static var active: ReportPrinter?
    private let webView = WKWebView(frame: NSRect(x: 0, y: 0, width: 1000, height: 800))
    private weak var window: NSWindow?

    static func print(html: String, from window: NSWindow?) {
        let printer = ReportPrinter()
        printer.window = window
        active = printer
        printer.webView.navigationDelegate = printer
        printer.webView.loadHTMLString(html, baseURL: nil)
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        let info = NSPrintInfo.shared.copy() as! NSPrintInfo
        info.horizontalPagination = .fit
        info.verticalPagination = .automatic
        info.orientation = .landscape
        let operation = webView.printOperation(with: info)
        operation.view?.frame = webView.bounds
        if let window {
            operation.runModal(for: window, delegate: nil, didRun: nil, contextInfo: nil)
        } else {
            operation.run()
        }
        ReportPrinter.active = nil
    }
}
