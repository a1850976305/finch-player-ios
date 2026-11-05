#if os(iOS)
import SwiftUI
import WebKit
import TVCore

// MARK: - WebHome view (step 1)
//
// A site that declares homePage in its subscription entry renders its home
// here, in a dedicated WKWebView, instead of the native recommendation page.
// The page is a normal web app: it calls window.fm (see WebHomeSDK below),
// the native side answers over WKScriptMessageHandler, and media goes
// through the existing player via store.playing = Channel(...).
// This view is iOS-only in step 1; other platforms get a placeholder from
// the same file so the shared App target still compiles.

struct WebHomeView: View {
    let site: Site
    let origin: URL
    @Environment(Store.self) private var store
    @Environment(\.dismiss) private var dismiss
    @State private var bridge: WebHomeBridge?
    @State private var chromeMode: String = "edge"
    @State private var toast: String?
    @State private var safeTop: CGFloat = 0
    @State private var safeBottom: CGFloat = 0
    @State private var safeLeft: CGFloat = 0
    @State private var safeRight: CGFloat = 0

    var body: some View {
        GeometryReader { geometry in
            ZStack {
                if let bridge, let url = site.webHomePageURL(origin: origin) {
                    WebHomeWebView(bridge: bridge, url: url)
                        .ignoresSafeArea(edges: chromeMode == "normal" ? [] : .all)
                } else {
                    ProgressView()
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        .background(Color.black)
                }
                if let toast {
                    Text(toast)
                        .font(.subheadline)
                        .foregroundStyle(.white)
                        .padding(.horizontal, 16)
                        .padding(.vertical, 10)
                        .background(Color.black.opacity(0.75), in: Capsule())
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
                        .padding(.bottom, 32)
                }
            }
            .onAppear {
                safeTop = geometry.safeAreaInsets.top
                safeBottom = geometry.safeAreaInsets.bottom
                safeLeft = geometry.safeAreaInsets.leading
                safeRight = geometry.safeAreaInsets.trailing
            }
            .onChange(of: geometry.safeAreaInsets) { _, insets in
                safeTop = insets.top
                safeBottom = insets.bottom
                safeLeft = insets.leading
                safeRight = insets.trailing
                bridge?.applyViewport(top: insets.top, bottom: insets.bottom, left: insets.leading, right: insets.trailing)
            }
        }
        .background(Color.black)
        .task {
            if bridge == nil {
                let gateway = WebHomeGateway()
                do {
                    let port = try await gateway.start()
                    let mode = site.webHomeChromeMode ?? "edge"
                    chromeMode = ["normal", "edge", "immersive"].contains(mode) ? mode : "edge"
                    let created = WebHomeBridge(site: site, gateway: gateway, port: port)
                    created.onToast = { text in
                        toast = text
                        Task {
                            try? await Task.sleep(for: .seconds(2))
                            if toast == text { toast = nil }
                        }
                    }
                    created.onPlay = { [weak created] channel in
                        _ = created
                        store.playing = channel
                    }
                    created.onBack = { dismiss() }
                    created.onChromeModeChange = { mode in chromeMode = mode }
                    bridge = created
                } catch {
                    // Gateway failure leaves the spinner; the page cannot run
                    // without fm.res, so failing loudly here beats a half page.
                    print("[WebHome] gateway failed: \(error)")
                }
            }
        }
        .onChange(of: bridge == nil) { _, isNil in
            // The bridge is created in .task, after first appear; push the
            // current safe area into the page as soon as it exists, so
            // --fm-safe-* is correct on first load, not only on rotation.
            if !isNil {
                bridge?.applyViewport(top: safeTop, bottom: safeBottom, left: safeLeft, right: safeRight)
            }
        }
        .onDisappear {
            bridge?.sendLifecycle("fmpause")
        }
        .onAppear {
            bridge?.sendLifecycle("fmresume", extra: nil)
        }
    }
}

// MARK: - WKWebView wrapper

private struct WebHomeWebView: UIViewRepresentable {
    let bridge: WebHomeBridge
    let url: URL

    func makeUIView(context: Context) -> WKWebView {
        let content = WKUserContentController()
        content.add(bridge, name: "fmBridge")
        // SDK at document start: pages detect window.fm immediately instead
        // of racing a post-load injection, and fmsdk fires on DOMContentLoaded.
        if let script = bridge.sdkScript {
            content.addUserScript(WKUserScript(source: script, injectionTime: .atDocumentStart, forMainFrameOnly: true))
        }
        let configuration = WKWebViewConfiguration()
        configuration.userContentController = content
        configuration.preferences.javaScriptEnabled = true
        configuration.allowsInlineMediaPlayback = true
        configuration.mediaTypesRequiringUserActionForPlayback = []
        // DOM storage + cookies on, mixed content allowed, wide viewport:
        // the webhtv WebView environment, ported to WKWebView.
        configuration.websiteDataStore = .default()
        if #available(iOS 15.0, *) {
            configuration.preferences.isElementFullscreenEnabled = true
        }
        let view = WKWebView(frame: .zero, configuration: configuration)
        view.navigationDelegate = context.coordinator
        view.customUserAgent = "Mozilla/5.0 (iPhone; CPU iPhone OS 17_0 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.0 Mobile/15E148 Safari/604.1"
        view.load(URLRequest(url: url))
        bridge.attach(webView: view)
        return view
    }

    func updateUIView(_ uiView: WKWebView, context: Context) {}

    func makeCoordinator() -> Coordinator { Coordinator() }

    final class Coordinator: NSObject, WKNavigationDelegate {
        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            // Second fmsdk chance for pages that missed DOMContentLoaded;
            // the SDK guards against a double dispatch.
            webView.evaluateJavaScript(
                "if(!window.__fmSDKEventSent){window.__fmSDKEventSent=true;document.dispatchEvent(new CustomEvent('fmsdk'));}",
                completionHandler: nil)
        }

        func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction, decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
            // Pages navigate themselves (search, detail, pagination). All
            // http(s) navigation stays inside this WebView in step 1.
            decisionHandler(.allow)
        }
    }
}

// MARK: - Bridge: native side of window.fm

@MainActor
final class WebHomeBridge: NSObject, ObservableObject, WKScriptMessageHandler {
    let site: Site
    let gateway: WebHomeGateway
    let port: Int
    var onToast: ((String) -> Void)?
    var onPlay: ((Channel) -> Void)?
    var onBack: (() -> Void)?
    var onChromeModeChange: ((String) -> Void)?

    private weak var webView: WKWebView?
    private var viewport = (top: CGFloat(0), bottom: CGFloat(0), left: CGFloat(0), right: CGFloat(0))

    init(site: Site, gateway: WebHomeGateway, port: Int) {
        self.site = site
        self.gateway = gateway
        self.port = port
    }

    func attach(webView: WKWebView) { self.webView = webView }

    /// The SDK source with the gateway port baked in. Built lazily so the
    /// port is known before the WebView is created.
    var sdkScript: String? {
        WebHomeSDK.source
            .replacingOccurrences(of: "__GATEWAY_PORT__", with: "\(port)")
            .replacingOccurrences(of: "__SITE_KEY__", with: site.key.replacingOccurrences(of: "'", with: "\\'"))
    }

    func applyViewport(top: CGFloat, bottom: CGFloat, left: CGFloat, right: CGFloat) {
        viewport = (top, bottom, left, right)
        let js = """
        (function(){
          var r=document.documentElement.style;
          r.setProperty('--fm-safe-top','\(Int(top))px');
          r.setProperty('--fm-safe-bottom','\(Int(bottom))px');
          r.setProperty('--fm-safe-left','\(Int(left))px');
          r.setProperty('--fm-safe-right','\(Int(right))px');
          document.dispatchEvent(new CustomEvent('fmviewport'));
        })();
        """
        webView?.evaluateJavaScript(js, completionHandler: nil)
    }

    func sendLifecycle(_ event: String, extra: [String: Any]? = nil) {
        var detail = ""
        if event == "fmresume", let extra {
            if let data = try? JSONSerialization.data(withJSONObject: extra),
               let text = String(data: data, encoding: .utf8) { detail = text }
        }
        // Built in pieces on purpose: a nested interpolation here once
        // dropped a closing paren and produced invalid JS.
        var js = "document.dispatchEvent(new CustomEvent('\(event)'"
        if !detail.isEmpty { js += ",{detail:\(detail)}" }
        js += "));"
        webView?.evaluateJavaScript(js, completionHandler: nil)
    }

    // MARK: WKScriptMessageHandler

    nonisolated func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
        guard let body = message.body as? [String: Any],
              let id = body["id"] as? String,
              let method = body["method"] as? String else { return }
        let args = body["args"] as? [String: Any] ?? [:]
        Task { @MainActor in
            await self.handle(id: id, method: method, args: args)
        }
    }

    private func handle(id: String, method: String, args: [String: Any]) async {
        switch method {
        case "req":
            let result = await req(args: args)
            sendResult(id: id, json: result)
        case "play":
            play(args: args)
            sendResult(id: id, json: "{\"ok\":true}")
        case "cacheGet":
            let key = cacheKey(args: args)
            let value = UserDefaults.standard.string(forKey: key)
            sendResult(id: id, json: value.map { "{\"value\":\(jsonString($0))}" } ?? "{\"value\":null}")
        case "cacheSet":
            let key = cacheKey(args: args)
            if let value = args["value"] as? String {
                UserDefaults.standard.set(value, forKey: key)
            }
            sendResult(id: id, json: "{\"ok\":true}")
        case "setChrome":
            if let mode = args["mode"] as? String, ["normal", "edge", "immersive"].contains(mode) {
                onChromeModeChange?(mode)
            }
            sendResult(id: id, json: "{\"ok\":true}")
        case "getViewport":
            sendResult(id: id, json: "{\"top\":\(Int(viewport.top)),\"bottom\":\(Int(viewport.bottom)),\"left\":\(Int(viewport.left)),\"right\":\(Int(viewport.right))}")
        case "log":
            if let message = args["message"] as? String { print("[WebHome] \(message)") }
            sendResult(id: id, json: "{\"ok\":true}")
        case "toast":
            if let message = args["message"] as? String { onToast?(message) }
            sendResult(id: id, json: "{\"ok\":true}")
        case "device":
            sendResult(id: id, json: "{\"platform\":\"iOS\",\"mode\":\"phone\",\"isLeanback\":false}")
        case "site":
            sendResult(id: id, json: "{\"key\":\(jsonString(site.key)),\"name\":\(jsonString(site.name))}")
        case "config":
            sendResult(id: id, json: "{\"siteKey\":\(jsonString(site.key)),\"chromeMode\":\(jsonString(site.webHomeChromeMode ?? "edge"))}")
        case "back":
            onBack?()
            sendResult(id: id, json: "{\"ok\":true}")
        case "reload":
            webView?.reload()
            sendResult(id: id, json: "{\"ok\":true}")
        default:
            // Step 2 methods (vodInline, vod, openVod, search, history,
            // preloadArtwork, ctrl, stat) are not answered yet; the SDK
            // never calls them in step 1, and an unknown method must fail
            // loudly instead of hanging a Promise.
            sendError(id: id, message: "unsupported method: \(method)")
        }
    }

    private func cacheKey(args: [String: Any]) -> String {
        let key = args["key"] as? String ?? ""
        let scope: String
        if let rawScope = args["scope"] as? String, !rawScope.isEmpty {
            scope = rawScope
        } else {
            scope = site.key
        }
        return "webhome.cache.\(site.key).\(scope).\(key)"
    }

    private func req(args: [String: Any]) async -> String {
        guard let urlString = args["url"] as? String, let url = URL(string: urlString) else {
            return "{\"ok\":false,\"status\":0,\"body\":\"\",\"error\":\"bad url\"}"
        }
        var request = URLRequest(url: url)
        if let method = args["method"] as? String, !method.isEmpty {
            request.httpMethod = method
        } else {
            request.httpMethod = "GET"
        }
        if let headers = args["headers"] as? [String: String] {
            for (field, value) in headers { request.setValue(value, forHTTPHeaderField: field) }
        }
        if let body = args["body"] as? String { request.httpBody = body.data(using: .utf8) }
        if let timeout = args["timeout"] as? Double { request.timeoutInterval = timeout }
        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            let status = (response as? HTTPURLResponse)?.statusCode ?? 0
            if let text = String(data: data, encoding: .utf8) {
                return "{\"ok\":true,\"status\":\(status),\"body\":\(jsonString(text)),\"error\":\"\"}"
            }
            // Binary bodies ride as base64; text pages (the step-1 case) never hit this.
            return "{\"ok\":true,\"status\":\(status),\"body\":\(jsonString(data.base64EncodedString())),\"isBase64\":true,\"error\":\"\"}"
        } catch {
            return "{\"ok\":false,\"status\":0,\"body\":\"\",\"error\":\(jsonString(error.localizedDescription))}"
        }
    }

    private func play(args: [String: Any]) {
        guard let urlString = args["url"] as? String, let url = URL(string: urlString) else { return }
        let title = args["title"] as? String ?? site.name
        let headers = args["headers"] as? [String: String] ?? [:]
        let credentials = args["credentials"] as? String ?? ""
        // webhtv rule: wrap through the gateway only when headers or login
        // state are present; a bare public m3u8/mpd must NOT be wrapped, or
        // relative-segment playlists break.
        let playURL: URL
        let playHeaders: [String: String]
        if !headers.isEmpty || credentials == "include" {
            playURL = gateway.resourceURL(for: urlString, headers: headers, credentials: credentials.isEmpty ? nil : credentials) ?? url
            playHeaders = [:]
        } else {
            playURL = url
            playHeaders = headers
        }
        onPlay?(Channel(name: title, group: site.name, url: playURL, headers: playHeaders))
    }

    // MARK: - Result transport (chunked past 12,000 chars, webhtv rule)

    private func sendResult(id: String, json: String) {
        guard let webView else { return }
        if json.count <= 12000 {
            webView.evaluateJavaScript("__fmResolve(\(jsonString(id)),\(jsonString(json)))", completionHandler: nil)
            return
        }
        // Chunked: the SDK reassembles __fmChunk parts, then __fmChunkDone
        // resolves the pending Promise with the joined JSON.
        let chunkSize = 8000
        var index = 0
        var offset = json.startIndex
        while offset < json.endIndex {
            let end = json.index(offset, offsetBy: chunkSize, limitedBy: json.endIndex) ?? json.endIndex
            let part = String(json[offset..<end])
            webView.evaluateJavaScript("__fmChunk(\(jsonString(id)),\(index),0,\(jsonString(part)))", completionHandler: nil)
            index += 1
            offset = end
        }
        webView.evaluateJavaScript("__fmChunkDone(\(jsonString(id)))", completionHandler: nil)
    }

    private func sendError(id: String, message: String) {
        guard let webView else { return }
        webView.evaluateJavaScript("__fmReject(\(jsonString(id)),\(jsonString(message)))", completionHandler: nil)
    }

    private func jsonString(_ text: String) -> String {
        guard let data = try? JSONSerialization.data(withJSONObject: [text]),
              let encoded = String(data: data, encoding: .utf8),
              encoded.count >= 2 else { return "\"\"" }
        // JSONSerialization of a one-element array gives ["..."]; strip brackets.
        return String(encoded.dropFirst().dropLast())
    }
}

// MARK: - JS SDK (injected at document start)

enum WebHomeSDK {
    /// __GATEWAY_PORT__ and __SITE_KEY__ are replaced by the bridge before
    /// injection. No Swift interpolation inside: the JS uses ${} nowhere, so
    /// a plain string replacement is safe.
    static let source = """
    (function(){
      if(window.__fmSDKInstalled) return; window.__fmSDKInstalled=true;
      var GATEWAY='http://127.0.0.1:__GATEWAY_PORT__';
      var pending={}; var chunks={};
      window.__fmResolve=function(id,json){var p=pending[id]; if(!p)return; delete pending[id]; try{p.resolve(JSON.parse(json));}catch(e){p.resolve(json);}};
      window.__fmReject=function(id,msg){var p=pending[id]; if(!p)return; delete pending[id]; p.reject(new Error(msg));};
      window.__fmChunk=function(id,idx,total,part){(chunks[id]=chunks[id]||[])[idx]=part;};
      window.__fmChunkDone=function(id){var parts=chunks[id]||[]; delete chunks[id]; window.__fmResolve(id,parts.join(''));};
      function call(method,args){return new Promise(function(res,rej){var id='fm'+Date.now()+'_'+Math.random().toString(36).slice(2); pending[id]={resolve:res,reject:rej}; window.webkit.messageHandlers.fmBridge.postMessage({id:id,method:method,args:args||{}});});}
      function resourceUrl(url,opts){opts=opts||{}; var h=opts.headers||{}; var q='url='+encodeURIComponent(url)+'&headers='+encodeURIComponent(JSON.stringify(h)); if(opts.credentials) q+='&credentials='+encodeURIComponent(opts.credentials); return GATEWAY+'/webResource?'+q;}
      var fongmi={
        net:{ request:function(url,opts){opts=opts||{}; return call('req',{url:url,method:opts.method||'GET',headers:opts.headers||{},body:opts.body||null,timeout:opts.timeout||30});}, resourceUrl:resourceUrl },
        player:{ playUrl:function(url,title,opts){opts=opts||{}; return call('play',{url:url,title:title||'',pic:opts.pic||'',wallPic:opts.wallPic||'',headers:opts.headers||{},credentials:opts.credentials||''});} },
        cache:{ get:function(k,scope){return call('cacheGet',{key:k,scope:scope||''});}, set:function(k,v,scope){return call('cacheSet',{key:k,value:v,scope:scope||''});} },
        ui:{ setChrome:function(o){return call('setChrome',o||{});}, getViewport:function(){return call('getViewport',{});}, restoreChrome:function(){return call('setChrome',{mode:'normal'});} },
        ext:{ log:function(m){return call('log',{message:String(m)});}, toast:function(m){return call('toast',{message:String(m)});}, info:function(){return call('device',{});} },
        device:function(){return call('device',{});}, site:function(){return call('site',{});}, config:function(){return call('config',{});},
        back:function(){return call('back',{});}, reload:function(){return call('reload',{});}
      };
      window.fongmi=fongmi;
      window.fm={ req:fongmi.net.request, res:resourceUrl, play:fongmi.player.playUrl, cache:fongmi.cache, ui:fongmi.ui, ext:fongmi.ext, device:fongmi.device, site:fongmi.site, config:fongmi.config, back:fongmi.back, reload:fongmi.reload };
      window.fongmiClient={mode:'phone', isLeanback:false};
      window.__fmSDKEventSent=false;
      document.addEventListener('DOMContentLoaded', function(){ if(!window.__fmSDKEventSent){window.__fmSDKEventSent=true; document.dispatchEvent(new CustomEvent('fmsdk'));} });
    })();
    """
}

#else
import SwiftUI
import TVCore

// WebHome is iOS-only in step 1; the shared App target still needs this
// symbol on macOS/tvOS, where it renders a placeholder instead of a WebView.
struct WebHomeView: View {
    let site: Site
    let origin: URL
    var body: some View {
        ContentUnavailableView("WebHome is not available on this platform", systemImage: "globe")
    }
}
#endif
