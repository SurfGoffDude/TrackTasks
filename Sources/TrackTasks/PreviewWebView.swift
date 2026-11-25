import SwiftUI
import TrackTasksCore
import WebKit

/// The page of one task's server. The page is untrusted: an empty temporary profile, no bridge to the app, only
/// addresses of this task's servers. Picks elements; never sends anything.
@MainActor @Observable
final class PreviewPage: NSObject {
    enum Phase: Equatable { case opening, open, closed(String) }

    struct Picked {
        var element: PreviewElement
        var png: Data
    }

    private(set) var phase = Phase.opening
    private(set) var web: WKWebView?
    private(set) var picking = false
    /// Address the page wanted to open; the person decides.
    var outside: URL?
    private(set) var note = ""

    @ObservationIgnored let policy: PreviewPolicy
    /// The port still belongs to the task's server.
    @ObservationIgnored private let confirm: @MainActor () async -> Bool
    /// Changes with every document: a snapshot of another one is dropped.
    @ObservationIgnored private var document = 0
    @ObservationIgnored private var confirmed = false
    @ObservationIgnored private var pickRun = 0

    static let world = WKContentWorld.world(name: "tracktasks-pick")

    init(policy: PreviewPolicy, confirm: @escaping @MainActor () async -> Bool) {
        self.policy = policy
        self.confirm = confirm
    }

    // MARK: Opening

    func open() async {
        guard web == nil, case .opening = phase else { return }
        guard await stillOurs() else { return }
        let rules: WKContentRuleList
        do { rules = try await Self.compile(policy.rules) } catch {
            return close("Правила блокировки чужих адресов не собрались, страница не открыта: \(error.localizedDescription)")
        }
        guard case .opening = phase, web == nil else { return }
        let c = WKWebViewConfiguration()
        c.websiteDataStore = .nonPersistent()
        c.userContentController.add(rules)
        // WebRTC and WebTransport don't go through the rules.
        let off = "for (const k of ['RTCPeerConnection', 'webkitRTCPeerConnection', 'WebTransport']) { try { Object.defineProperty(window, k, { value: undefined, configurable: false, writable: false }) } catch (e) {} }"
        c.userContentController.addUserScript(WKUserScript(source: off, injectionTime: .atDocumentStart, forMainFrameOnly: false))
        c.preferences.javaScriptCanOpenWindowsAutomatically = false
        c.preferences.isElementFullscreenEnabled = false
        c.mediaTypesRequiringUserActionForPlayback = .all
        let w = WKWebView(frame: CGRect(x: 0, y: 0, width: 1024, height: 700), configuration: c)
        w.navigationDelegate = self
        w.uiDelegate = self
        w.allowsLinkPreview = false
        w.allowsMagnification = false
        w.allowsBackForwardNavigationGestures = false
        w.isInspectable = true
        web = w
        phase = .open
        load()
    }

    private static func compile(_ json: String) async throws -> WKContentRuleList {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("tracktasks-preview-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        guard let store = WKContentRuleListStore(url: dir),
              let list = try await store.compileContentRuleList(forIdentifier: "preview", encodedContentRuleList: json) else {
            throw PreviewFolder.Failure(message: "WebKit не принял правила")
        }
        return list
    }

    private func load() {
        guard let web, let u = policy.start else { return }
        web.load(URLRequest(url: u, cachePolicy: .reloadIgnoringLocalCacheData))
    }

    func reload() async {
        note = ""
        outside = nil
        guard let web, await stillOurs() else { return }
        if policy.decide(web.url) == .show { web.reloadFromOrigin() } else { load() }
    }

    /// The server stopped or changed: the page is gone and nothing can be picked.
    func close(_ why: String) {
        cancelPick()
        confirmed = false
        document += 1
        phase = .closed(why)
        web?.stopLoading()
        web?.navigationDelegate = nil
        web?.uiDelegate = nil
        web = nil
    }

    private func stillOurs() async -> Bool {
        confirmed = await confirm()
        if !confirmed {
            if case .closed = phase {} else {
                close("Не подтверждено, что порт \(policy.port) слушает сервер этой задачи: он ещё не запустился, уже остановлен или процесс ушёл из-под контроля. Страницу можно открыть во внешнем браузере.")
            }
            return false
        }
        if case .closed = phase { return false }
        return true
    }

    // MARK: Picking

    var canPick: Bool {
        guard case .open = phase, let web else { return false }
        return policy.canPick(web.url, mainFrame: true, serverConfirmed: confirmed)
    }

    /// Waits for the person's click; nil = cancelled or the page changed.
    func pick() async -> Picked? {
        guard !picking, canPick, let web, await stillOurs(), canPick, !picking else { return nil }
        picking = true
        note = ""
        pickRun += 1
        let run = pickRun, doc = document
        defer { if pickRun == run { picking = false } }
        guard let raw = try? await web.callAsyncJavaScript(Self.script, arguments: [:], in: nil, contentWorld: Self.world) as? [String: Any],
              pickRun == run, picking, doc == document else { return nil }
        guard await stillOurs(), canPick, doc == document else { return dropped() }
        // The address is the app's knowledge, not the page's word.
        var r = raw
        r["url"] = web.url?.absoluteString ?? ""
        guard let e = PreviewElement(r), let rect = e.shot(in: web.bounds) else {
            note = "Элемент не виден в окне"
            return nil
        }
        guard let png = await Self.snapshot(web, rect) else {
            note = "Не удалось сделать снимок"
            return nil
        }
        guard doc == document, canPick, pickRun == run else { return dropped() }
        return Picked(element: e, png: png)
    }

    private func dropped() -> Picked? {
        note = "Страница сменилась во время выбора — снимок отброшен"
        return nil
    }

    func cancelPick() {
        pickRun += 1
        guard picking else { return }
        picking = false
        web?.evaluateJavaScript("globalThis.ttCancel && globalThis.ttCancel()", in: nil, in: Self.world) { _ in }
    }

    private static func snapshot(_ web: WKWebView, _ rect: CGRect) async -> Data? {
        var width = min(rect.width, 1600)
        for _ in 0..<4 {
            let c = WKSnapshotConfiguration()
            c.rect = rect
            c.snapshotWidth = NSNumber(value: Double(width))
            guard let image = try? await web.takeSnapshot(configuration: c), let tiff = image.tiffRepresentation,
                  let png = NSBitmapImageRep(data: tiff)?.representation(using: .png, properties: [:]) else { return nil }
            if png.count <= PreviewFolder.maxBytes { return png }
            width /= 2
        }
        return nil
    }

    /// Runs in a world of its own: the page's scripts can't call or replace it. Only real events of the person count.
    /// Values of fields, scripts and styles are left out.
    static let script = """
    return await new Promise((resolve) => {
      if (globalThis.ttCancel) globalThis.ttCancel();
      const box = document.createElement('div');
      box.style.cssText = 'all:initial;position:fixed;pointer-events:none;z-index:2147483647;border:2px solid #0a84ff;background:rgba(10,132,255,.15);box-sizing:border-box;display:none';
      document.documentElement.appendChild(box);
      const names = ['mousemove', 'mousedown', 'mouseup', 'pointerdown', 'pointerup', 'click', 'dblclick', 'contextmenu', 'keydown'];
      let done = false;
      const stop = (v) => {
        if (done) return;
        done = true;
        for (const n of names) window.removeEventListener(n, on, true);
        box.remove();
        delete globalThis.ttCancel;
        requestAnimationFrame(() => requestAnimationFrame(() => {}));
        setTimeout(() => resolve(v), 60);
      };
      globalThis.ttCancel = () => stop(null);
      const at = (e) => document.elementFromPoint(e.clientX, e.clientY);
      const step = (el) => {
        let s = el.localName;
        if (el.id) return s + '#' + CSS.escape(el.id);
        const cls = [...el.classList].slice(0, 3).map((c) => '.' + CSS.escape(c)).join('');
        const same = el.parentElement ? [...el.parentElement.children].filter((c) => c.localName === el.localName) : [];
        return s + cls + (same.length > 1 ? ':nth-of-type(' + (same.indexOf(el) + 1) + ')' : '');
      };
      const path = (el) => {
        const out = [];
        for (let e = el; e && out.length < 12; e = e.parentElement) {
          out.unshift(step(e));
          if (e.id) break;
        }
        return out.join(' > ');
      };
      const secret = 'input,textarea,select,option,[contenteditable]:not([contenteditable=false])';
      const clean = (el) => {
        const c = el.cloneNode(true);
        for (const x of c.querySelectorAll('script,style,noscript,template,iframe')) x.remove();
        for (const x of [c, ...c.querySelectorAll('*')]) {
          if (x.matches(secret)) {
            x.removeAttribute('value');
            if (!x.matches('select,input')) x.textContent = '';
          }
          for (const a of [...x.attributes]) if (/^on|^srcdoc$/i.test(a.name) || a.value.length > 300) x.removeAttribute(a.name);
        }
        return c;
      };
      const on = (e) => {
        if (!e.isTrusted) return;
        if (e.type === 'keydown') { if (e.key === 'Escape') { e.preventDefault(); e.stopImmediatePropagation(); stop(null); } return; }
        e.preventDefault();
        e.stopImmediatePropagation();
        const el = at(e);
        if (!el) return;
        const r = el.getBoundingClientRect();
        if (e.type === 'mousemove') {
          Object.assign(box.style, { display: 'block', left: r.left + 'px', top: r.top + 'px', width: r.width + 'px', height: r.height + 'px' });
        } else if (e.type === 'click') {
          const inField = el.closest(secret);
          const c = inField ? null : clean(el);
          const text = c ? (el.querySelector(secret) || el.matches('script,style') ? c.textContent : el.innerText) || '' : '';
          const html = (inField ? clean(el) : c).outerHTML;
          stop({ path: path(el), text: text.slice(0, 6000), html: html.slice(0, 20000), x: r.left, y: r.top, width: r.width, height: r.height,
                 viewWidth: innerWidth, viewHeight: innerHeight });
        }
      };
      for (const n of names) window.addEventListener(n, on, { capture: true, passive: false });
    });
    """
}

extension PreviewPage: WKNavigationDelegate, WKUIDelegate {
    func webView(_ webView: WKWebView, decidePolicyFor a: WKNavigationAction) async -> WKNavigationActionPolicy {
        guard webView === web, !a.shouldPerformDownload else { return .cancel }
        let main = a.targetFrame?.isMainFrame ?? true
        guard allowed(a.request.url, main: main), a.targetFrame != nil else { return .cancel }
        if main {
            cancelPick()
            guard await stillOurs() else { return .cancel }
        }
        return .allow
    }

    func webView(_ webView: WKWebView, decidePolicyFor r: WKNavigationResponse) async -> WKNavigationResponsePolicy {
        guard webView === web, r.canShowMIMEType, allowed(r.response.url, main: r.isForMainFrame) else { return .cancel }
        return .allow
    }

    private func allowed(_ u: URL?, main: Bool) -> Bool {
        switch policy.decide(u, mainFrame: main) {
        case .show: return true
        case .offerOutside(let u):
            outside = u
            return false
        case .deny:
            if main { note = "Адрес запрещён: \(UntrustedText.line(u?.scheme ?? "неизвестный")):" }
            return false
        }
    }

    func webView(_ webView: WKWebView, didCommit navigation: WKNavigation!) {
        document += 1
        cancelPick()
        // Whatever got here past the checks.
        if policy.decide(webView.url) != .show { close("Страница ушла на посторонний адрес — превью закрыто") }
    }

    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) { failed(error) }
    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) { failed(error) }

    private func failed(_ e: Error) {
        let e = e as NSError
        // Cancelled, or refused by the policy.
        guard !(e.domain == NSURLErrorDomain && e.code == NSURLErrorCancelled), !(e.domain == "WebKitErrorDomain" && e.code == 102) else { return }
        note = "Страница не загрузилась: \(e.localizedDescription)"
    }

    func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
        document += 1
        cancelPick()
        note = "Процесс страницы завершился — обнови её"
    }

    /// No passwords of the person, whoever asks.
    func webView(_ webView: WKWebView, respondTo challenge: URLAuthenticationChallenge) async -> (URLSession.AuthChallengeDisposition, URLCredential?) {
        (.cancelAuthenticationChallenge, nil)
    }

    func webView(_ webView: WKWebView, navigationAction: WKNavigationAction, didBecome download: WKDownload) { download.cancel { _ in } }
    func webView(_ webView: WKWebView, navigationResponse: WKNavigationResponse, didBecome download: WKDownload) { download.cancel { _ in } }

    func webView(_ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration, for a: WKNavigationAction,
                 windowFeatures: WKWindowFeatures) -> WKWebView? {
        // The same site in the same window; another one only outside.
        if allowed(a.request.url, main: true) { webView.load(a.request) }
        return nil
    }

    func webView(_ webView: WKWebView, runOpenPanelWith parameters: WKOpenPanelParameters, initiatedByFrame frame: WKFrameInfo) async -> [URL]? { nil }

    func webView(_ webView: WKWebView, decideMediaCapturePermissionsFor origin: WKSecurityOrigin, initiatedBy frame: WKFrameInfo,
                 type: WKMediaCaptureType) async -> WKPermissionDecision { .deny }
}

struct PreviewWebView: NSViewRepresentable {
    let web: WKWebView
    func makeNSView(context: Context) -> WKWebView { web }
    func updateNSView(_ v: WKWebView, context: Context) {}
}
