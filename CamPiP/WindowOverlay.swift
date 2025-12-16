import AppKit
import WebKit

final class WebOverlayController: NSWindowController, NSWindowDelegate, WKNavigationDelegate {

    private var web: WKWebView!             // назначаем ПОСЛЕ super.init
    private var keepAliveView: NSView?

    init(url: URL, title: String = "Web Overlay") {
        // 1) Окно
        let startSize = NSSize(width: 480, height: 270)
        let screen = NSScreen.main?.visibleFrame ?? .init(x: 0, y: 0, width: 1200, height: 800)
        let origin = CGPoint(x: screen.maxX - startSize.width - 24, y: screen.minY + 24)

        let panel = NSPanel(
            contentRect: NSRect(origin: origin, size: startSize),
            styleMask: [.nonactivatingPanel, .titled, .resizable],
            backing: .buffered, defer: false
        )
        panel.title = title
        panel.titleVisibility = .hidden
        panel.titlebarAppearsTransparent = true
        panel.styleMask.insert(.fullSizeContentView)

        // Для надёжного рендера WebKit делаем окно НЕ прозрачным
        panel.isOpaque = true
        panel.backgroundColor = .windowBackgroundColor

        panel.isFloatingPanel = true
        panel.hidesOnDeactivate = false
        panel.level = .popUpMenu
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle]
        panel.isMovableByWindowBackground = true
        panel.hasShadow = true
        panel.minSize = NSSize(width: 300, height: 170)

        // 2) Контейнер
        let host = NSView()
        host.wantsLayer = true
        host.layer?.masksToBounds = true
        host.layer?.cornerRadius = 10
        host.layer?.borderWidth = 1
        host.layer?.borderColor = NSColor.windowBackgroundColor.withAlphaComponent(0.3).cgColor

        // ВАЖНО: сначала super.init, потом self.*
        super.init(window: panel)

        // 3) WebView
        let cfg = WKWebViewConfiguration()
        cfg.websiteDataStore = .default()
        cfg.defaultWebpagePreferences.allowsContentJavaScript = true
        // На macOS нет allowsInlineMediaPlayback, а автоплей включим так:
        cfg.mediaTypesRequiringUserActionForPlayback = []

        let web = WKWebView(frame: .zero, configuration: cfg)
        web.navigationDelegate = self
        web.translatesAutoresizingMaskIntoConstraints = false
        // Прозрачность самого WebView можно включить позже, когда убедимся что всё рисуется:
        // web.setValue(false, forKey: "drawsBackground")

        host.addSubview(web)
        NSLayoutConstraint.activate([
            web.leadingAnchor.constraint(equalTo: host.leadingAnchor),
            web.trailingAnchor.constraint(equalTo: host.trailingAnchor),
            web.topAnchor.constraint(equalTo: host.topAnchor),
            web.bottomAnchor.constraint(equalTo: host.bottomAnchor)
        ])

        panel.contentView = host
        self.keepAliveView = host
        self.web = web

        panel.delegate = self
        window?.makeKeyAndOrderFront(nil)

        // Загружаем страницу
        web.load(URLRequest(url: normalizedURL(url)))
    }

    required init?(coder: NSCoder) { fatalError() }

    // Подгон аспекта под реальный <video> (YouTube и др.)
    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        let js = """
        new Promise(r=>{
          const v=document.querySelector('video');
          if(!v){ r([0,0]); return; }
          const done=()=>r([v.videoWidth||0, v.videoHeight||0]);
          if (v.readyState>=1) done(); else v.addEventListener('loadedmetadata', done, {once:true});
        });
        """
        webView.evaluateJavaScript(js) { [weak self] res, _ in
            guard let self, let arr = res as? [CGFloat], arr.count == 2, arr[0] > 0, arr[1] > 0 else { return }
            self.applyAspect(arr[0] / max(arr[1], 1))
        }
    }

    private func applyAspect(_ aspect: CGFloat) {
        guard let panel = window else { return }
        panel.contentAspectRatio = NSSize(width: aspect, height: 1)

        var f = panel.frame
        let scale = panel.backingScaleFactor
        let content = panel.contentRect(forFrameRect: f)
        let newContentWidth = (content.height * aspect * scale).rounded() / scale
        let delta = newContentWidth - content.width

        let right  = f.maxX
        let bottom = f.minY
        f.size.width += delta
        f.origin.x = right - f.size.width
        f.origin.y = bottom
        panel.setFrame(f, display: true)
    }

    private func normalizedURL(_ url: URL) -> URL {
        guard let host = url.host else { return url }
        if host.contains("youtube.com"),
           let q = URLComponents(url: url, resolvingAgainstBaseURL: false)?
                .queryItems?.first(where: { $0.name == "v" })?.value {
            return URL(string: "https://www.youtube.com/embed/\(q)?autoplay=1&playsinline=1") ?? url
        }
        return url
    }

    // «Клик-сквозь»
    func setClickThrough(_ on: Bool) { window?.ignoresMouseEvents = on }
}
