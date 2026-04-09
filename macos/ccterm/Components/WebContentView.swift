import SwiftUI

/// Generic SwiftUI wrapper for WebViewHeightLoader.
/// Always renders the WebView; height is 0 while loading, then expands to content height.
/// Keeping a single View identity prevents SwiftUI from re-inserting the WebView on state change.
struct WebContentView: View {
    let loader: WebViewHeightLoader
    var maxHeight: CGFloat

    var body: some View {
        let height: CGFloat = switch loader.state {
        case .loading: 0
        case .ready(let h): min(h, maxHeight)
        }
        WebViewRepresentable(webView: loader.webView)
            .frame(height: height)
            .animation(.easeOut(duration: 0.2), value: height)
    }
}
