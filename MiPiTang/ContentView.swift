import SwiftUI
import WebKit

/// 用 WKWebView 加载打包在 App 内的 index.html
struct ContentView: UIViewRepresentable {

    func makeUIView(context: Context) -> WKWebView {
        let config = WKWebViewConfiguration()
        config.allowsInlineMediaPlayback = true
        config.mediaTypesRequiringUserActionForPlayback = []

        let webView = WKWebView(frame: .zero, configuration: config)
        webView.navigationDelegate = context.coordinator
        context.coordinator.webView = webView
        webView.scrollView.bounces = false
        webView.scrollView.isScrollEnabled = false
        webView.scrollView.contentInsetAdjustmentBehavior = .never
        webView.isOpaque = false
        webView.backgroundColor = UIColor(red: 1.0, green: 0.91, blue: 0.87, alpha: 1.0)
        webView.allowsBackForwardNavigationGestures = false

        if let url = Bundle.main.url(forResource: "index", withExtension: "html", subdirectory: "web") {
            webView.loadFileURL(url, allowingReadAccessTo: url.deletingLastPathComponent())
        }
        return webView
    }

    func updateUIView(_ uiView: WKWebView, context: Context) {}

    func makeCoordinator() -> Coordinator { Coordinator() }

    final class Coordinator: NSObject, WKNavigationDelegate {

        weak var webView: WKWebView?

        /// 公告地址（优先 ghproxy 镜像，失败自动换直连）
        private let noticeURLs = [
            "https://ghproxy.net/https://raw.githubusercontent.com/htpxfcqkgm-hub/mipitang-assets/main/version.json",
            "https://raw.githubusercontent.com/htpxfcqkgm-hub/mipitang-assets/main/version.json"
        ]

        /// 网页里的外部链接（如「反馈」表单）交给系统 Safari 打开
        func webView(_ webView: WKWebView,
                     decidePolicyFor navigationAction: WKNavigationAction,
                     decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
            if let url = navigationAction.request.url,
               let scheme = url.scheme?.lowercased(),
               scheme == "http" || scheme == "https" {
                UIApplication.shared.open(url)
                decisionHandler(.cancel)
                return
            }
            decisionHandler(.allow)
        }

        /// 页面加载完成后拉公告（此时 DOM 已就绪，__mptApplyCloud 已定义）
        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            self.webView = webView
            fetchCloudNotice()
        }

        // MARK: - 原生拉取 + JS 注入（绕开 WKWebView 跨域限制）

        func fetchCloudNotice() {
            let ts = Int(Date().timeIntervalSince1970)
            let urls = noticeURLs.map { "\($0)?t=\(ts)" }
            tryFetch(urls, attempt: 0)
        }

        private func tryFetch(_ urls: [String], attempt: Int) {
            guard attempt < urls.count, let url = URL(string: urls[attempt]) else { return }

            var request = URLRequest(url: url,
                                     cachePolicy: .reloadIgnoringLocalCacheData,
                                     timeoutInterval: 12)
            request.setValue("no-cache", forHTTPHeaderField: "Cache-Control")
            request.setValue("application/json", forHTTPHeaderField: "Accept")

            URLSession.shared.dataTask(with: request) { [weak self] data, response, error in
                guard let self = self else { return }

                let status = (response as? HTTPURLResponse)?.statusCode ?? 0
                if error == nil, status == 200, let data = data, !data.isEmpty,
                   let json = String(data: data, encoding: .utf8) {
                    let trimmed = json.trimmingCharacters(in: .whitespacesAndNewlines)
                    if trimmed.hasPrefix("{") || trimmed.hasPrefix("[") {
                        DispatchQueue.main.async { self.inject(trimmed) }
                        return
                    }
                }

                // 本次失败：换下一个地址重试
                self.tryFetch(urls, attempt: attempt + 1)
            }.resume()
        }

        private func inject(_ json: String) {
            guard let webView = webView else { return }
            // 1) 先把数据挂到全局变量 + 广播事件（处理函数没就绪时网页也能自己取）
            // 2) 再直接调用 __mptApplyCloud 弹公告
            let js = """
            (function(){
              try {
                window.__MPT_CLOUD = \(json);
                window.dispatchEvent(new Event('mpt-cloud'));
              } catch (e) {}
              if (typeof window.__mptApplyCloud !== 'function') { return 'no-handler'; }
              try { window.__mptApplyCloud(\(json)); return 'ok'; } catch (e) { return 'error:' + e; }
            })();
            """
            webView.evaluateJavaScript(js) { result, error in
                if let error = error {
                    print("注入公告 JS 失败: \(error)")
                } else if let result = result {
                    print("公告注入结果: \(result)")
                }
            }
        }
    }
}
