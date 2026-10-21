import SwiftUI
import UIKit
import WebKit

// MARK: - 触觉反馈（震动）

/// 三种力度：light 普通 / medium 重要 / heavy 警报
enum Haptics {
    private static let lightGen = UIImpactFeedbackGenerator(style: .light)
    private static let mediumGen = UIImpactFeedbackGenerator(style: .medium)
    private static let heavyGen = UIImpactFeedbackGenerator(style: .heavy)
    private static let selectGen = UISelectionFeedbackGenerator()
    private static var lastAt: TimeInterval = 0

    static func prepare() {
        lightGen.prepare()
        mediumGen.prepare()
        heavyGen.prepare()
        selectGen.prepare()
    }

    static func play(_ type: String) {
        // 限流：70ms 内重复触发只算一次，避免连点狂震
        let now = Date().timeIntervalSince1970
        // heavy 是重要事件，即使紧跟按钮轻震也要放行
        if type != "heavy" && now - lastAt < 0.07 { return }
        lastAt = now

        switch type {
        case "heavy":
            heavyGen.impactOccurred()
            heavyGen.prepare()
        case "medium":
            mediumGen.impactOccurred()
            mediumGen.prepare()
        case "selection":
            selectGen.selectionChanged()
            selectGen.prepare()
        default:
            lightGen.impactOccurred()
            lightGen.prepare()
        }
    }
}

/// 网页 JS → 原生 的震动通道
final class HapticBridge: NSObject, WKScriptMessageHandler {
    func userContentController(_ userContentController: WKUserContentController,
                               didReceive message: WKScriptMessage) {
        guard message.name == "haptic", let type = message.body as? String else { return }
        Haptics.play(type)
    }
}

// MARK: - 网页 ↔ 原生 状态桥

/// 让 SwiftUI 层能操作网页里的中英文切换按钮
final class WebBridge: ObservableObject {
    @Published var showNativeLang = false
    @Published var langText = "🌐"

    weak var webView: WKWebView?

    /// 是否支持原生液态玻璃（iOS 26+）
    static var nativeGlassSupported: Bool {
        if #available(iOS 26.0, *) { return true }
        return false
    }

    /// 页面加载后检查网页里有没有可见的 #langBtn（没有就不显示原生按钮）
    func probeLangButton() {
        guard let wv = webView else { return }
        let js = """
        (function(){
          var b = document.getElementById('langBtn');
          if (!b) { return 'none'; }
          if (window.getComputedStyle(b).display === 'none') { return 'none'; }
          return 'ok|' + (b.textContent || '').trim();
        })();
        """
        wv.evaluateJavaScript(js) { [weak self] result, _ in
            guard let self = self, let s = result as? String else { return }
            guard s.hasPrefix("ok|") else { return }
            let text = String(s.dropFirst(3)).trimmingCharacters(in: .whitespacesAndNewlines)
            if !text.isEmpty { self.langText = text }
            guard WebBridge.nativeGlassSupported else { return }   // 老系统不动网页那颗
            self.showNativeLang = true
            // 网页那颗隐藏掉，避免双按钮
            wv.evaluateJavaScript("var b=document.getElementById('langBtn'); if(b){ b.style.display='none'; }",
                                  completionHandler: nil)
        }
    }

    /// 点原生按钮 → 触发网页里的切换逻辑 → 同步按钮上的旗子
    func toggleLang() {
        guard let wv = webView else { return }
        let js = """
        (function(){
          var b = document.getElementById('langBtn');
          if (!b) { return ''; }
          b.click();
          return (b.textContent || '').trim();
        })();
        """
        wv.evaluateJavaScript(js) { [weak self] result, _ in
            guard let self = self else { return }
            if let s = result as? String, !s.isEmpty { self.langText = s }
            // 有的页面点完才改文字，稍后再取一次
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) {
                let js2 = "(function(){var b=document.getElementById('langBtn'); return b ? (b.textContent||'').trim() : '';})();"
                wv.evaluateJavaScript(js2) { r2, _ in
                    if let s2 = r2 as? String, !s2.isEmpty { self.langText = s2 }
                }
            }
        }
    }
}

// MARK: - 原生液态玻璃按钮（iOS 26 / Xcode 26）

/// 真·Liquid Glass：调用系统 glassEffect。老系统/老编译器自动走下面的兜底样式。
@available(iOS 26.0, *)
struct LangGlassButton: View {
    let text: String
    let action: () -> Void

    var body: some View {
        #if compiler(>=6.2)
        Button(action: action) {
            Text(text)
                .font(.system(size: 20))
                .frame(width: 24, height: 24)
                .padding(10)
        }
        .buttonStyle(.plain)
        .glassEffect(.regular.interactive(), in: Circle())
        #else
        Button(action: action) {
            Text(text)
                .font(.system(size: 20))
                .frame(width: 24, height: 24)
                .padding(10)
                .background(.ultraThinMaterial, in: Circle())
                .overlay(Circle().strokeBorder(.white.opacity(0.7), lineWidth: 1))
        }
        .buttonStyle(.plain)
        #endif
    }
}

// MARK: - 根视图

struct ContentView: View {
    @StateObject private var bridge = WebBridge()

    var body: some View {
        ZStack(alignment: .topTrailing) {
            WebView(bridge: bridge)
                .ignoresSafeArea()

            if bridge.showNativeLang {
                if #available(iOS 26.0, *) {
                    LangGlassButton(text: bridge.langText) {
                        bridge.toggleLang()   // 语言切换不震
                    }
                    .padding(.top, 12)
                    .padding(.trailing, 12)
                }
            }
        }
    }
}

// MARK: - WKWebView

/// 用 WKWebView 加载打包在 App 内的 index.html
struct WebView: UIViewRepresentable {

    @ObservedObject var bridge: WebBridge

    // v0.47：不再全局拦截按钮点击。震动只在网页 triggerVibrate() 里显式调用，
    // 这里只保留 haptic 消息通道（config 里已注册），无需注入脚本。

    func makeUIView(context: Context) -> WKWebView {
        let config = WKWebViewConfiguration()
        config.allowsInlineMediaPlayback = true
        config.mediaTypesRequiringUserActionForPlayback = []

        // 震动桥接（在 load 之前挂好，网页里才能 postMessage）
        config.userContentController.add(context.coordinator.haptic, name: "haptic")

        let webView = WKWebView(frame: .zero, configuration: config)
        webView.navigationDelegate = context.coordinator
        context.coordinator.webView = webView
        context.coordinator.bridge = bridge
        bridge.webView = webView
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
        weak var bridge: WebBridge?
        let haptic = HapticBridge()

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
            self.bridge?.webView = webView
            Haptics.prepare()   // 预热震动器，第一次点击不延迟
            fetchCloudNotice()
            // 找网页里的中英文按钮，找到就换成原生液态玻璃
            self.bridge?.probeLangButton()
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) { [weak self] in
                if self?.bridge?.showNativeLang == false { self?.bridge?.probeLangButton() }
            }
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
