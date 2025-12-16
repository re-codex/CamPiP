import SwiftUI
import AppKit
import ScreenCaptureKit
import AVFoundation

// MARK: - Захват камеры (как у тебя)
final class CameraCapture: NSObject {
    let session = AVCaptureSession()
    override init() {
        super.init()
        session.sessionPreset = .vga640x480
        let device = AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: .front)
            ?? AVCaptureDevice.default(for: .video)
        guard
            let device,
            let input = try? AVCaptureDeviceInput(device: device),
            session.canAddInput(input)
        else { return }
        session.beginConfiguration()
        session.addInput(input)
        session.commitConfiguration()
    }
    func start() { guard !session.isRunning else { return }; session.startRunning() }
    func stop()  { guard  session.isRunning else { return }; session.stopRunning()  }
}

// MARK: - NSView с превью камеры
final class CameraPreviewView: NSView {
    let videoLayer = AVCaptureVideoPreviewLayer()
    init(session: AVCaptureSession) {
        super.init(frame: .zero)
        wantsLayer = true
        videoLayer.session = session
        videoLayer.videoGravity = .resizeAspectFill
        layer = videoLayer
        layer?.cornerRadius = 10
        layer?.masksToBounds = true
        layer?.borderWidth = 1
        layer?.borderColor = NSColor.windowBackgroundColor.withAlphaComponent(0.3).cgColor
    }
    required init?(coder: NSCoder) { fatalError() }
    override func layout() {
        super.layout()
        CATransaction.begin(); CATransaction.setDisableActions(true)
        videoLayer.frame = bounds
        CATransaction.commit()
    }
}

// MARK: - Плавающее окно поверх всех окон и во всех Spaces
final class OverlayWindowController: NSWindowController, NSWindowDelegate {
    private var keepAliveView: NSView?

    init(session: AVCaptureSession) {
        let size = NSSize(width: 300, height: 200)
        let screen = NSScreen.main?.visibleFrame ?? .init(x: 0, y: 0, width: 1200, height: 800)
        let origin = CGPoint(x: screen.maxX - size.width - 24, y: screen.minY + 24)

        let panel = NSPanel(
            contentRect: NSRect(origin: origin, size: size),
            styleMask: [.nonactivatingPanel, .titled, .resizable],
            backing: .buffered,
            defer: false
        )

        panel.level = .popUpMenu   // вместо .screenSaver
        panel.title = "SelfView"
        panel.titleVisibility = .hidden
        panel.titlebarAppearsTransparent = true

        panel.minSize = NSSize(width: 240, height: 135)
        panel.isFloatingPanel = true
        panel.hidesOnDeactivate = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle]
        panel.isMovableByWindowBackground = true
        panel.isOpaque = false
        panel.backgroundColor = .windowBackgroundColor
        panel.hasShadow = true

        let view = CameraPreviewView(session: session)
        view.autoresizingMask = [.width, .height]
        panel.contentView = view
        self.keepAliveView = view

        super.init(window: panel)
        panel.delegate = self
        window?.makeKeyAndOrderFront(nil)
    }

    func windowDidEndLiveResize(_ notification: Notification) {
        guard let win = window, let screen = win.screen?.visibleFrame else { return }
        var f = win.frame
        if f.minY < screen.minY { f.origin.y = screen.minY }
        if f.maxX > screen.maxX { f.origin.x = screen.maxX - f.width }
        if f.maxY > screen.maxY { f.origin.y = screen.maxY - f.height }
        win.setFrame(f, display: true)
    }

    init(layer: AVSampleBufferDisplayLayer, title: String = "OnTop", aspect: CGFloat? = nil) {
        let startSize = NSSize(width: 320, height: 200)
        let screen = NSScreen.main?.visibleFrame ?? .init(x: 0, y: 0, width: 1200, height: 800)
        let origin = CGPoint(x: screen.maxX - startSize.width - 24, y: screen.minY + 24)

        let panel = NSPanel(
            contentRect: NSRect(origin: origin, size: startSize),
            styleMask: [.nonactivatingPanel, .titled, .resizable],
            backing: .buffered,
            defer: false
        )

        panel.title = title
        panel.titleVisibility = .hidden
        panel.titlebarAppearsTransparent = true
        panel.styleMask.insert(.fullSizeContentView)

        panel.isFloatingPanel = true
        panel.hidesOnDeactivate = false
        panel.level = .popUpMenu
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle]
        panel.isMovableByWindowBackground = true
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = true

        panel.standardWindowButton(.closeButton)?.isHidden = true
        panel.standardWindowButton(.miniaturizeButton)?.isHidden = true
        panel.standardWindowButton(.zoomButton)?.isHidden = true

        panel.minSize = NSSize(width: 240, height: 135)

        let host = LayerHostView(sampleLayer: layer)
        host.translatesAutoresizingMaskIntoConstraints = true
        host.autoresizingMask = [.width, .height]
        panel.contentView = host
        self.keepAliveView = host

        if let aspect {
            panel.contentAspectRatio = NSSize(width: aspect, height: 1)

            var f = panel.frame
            let scale = panel.backingScaleFactor
            let content = panel.contentRect(forFrameRect: f)
            let newContentWidth = (content.height * aspect * scale).rounded() / scale

            f.size.width += (newContentWidth - content.width)

            let right  = f.maxX
            let bottom = f.minY
            f.origin.x = right - f.size.width
            f.origin.y = bottom

            panel.setFrame(f, display: false)
        }

        super.init(window: panel)
        panel.delegate = self

        func applyScale() {
            let s = panel.backingScaleFactor
            host.layer?.contentsScale = s
            host.displayLayer.contentsScale = s
        }
        applyScale()
        NotificationCenter.default.addObserver(
            forName: NSWindow.didChangeBackingPropertiesNotification,
            object: panel, queue: .main
        ) { _ in applyScale() }

        window?.makeKeyAndOrderFront(nil)
    }

    required init?(coder: NSCoder) { fatalError() }
}

// MARK: - SwiftUI UI
struct ContentView: View {
    // КАМЕРА
    @State private var camera = CameraCapture()
    @State private var cameraWC: OverlayWindowController?
    @State private var cameraRunning = false

    // ЗЕРКАЛО ОКНА
    @State private var mirror = WindowMirror()
    @State private var mirrorWC: OverlayWindowController?
    @State private var mirroring = false

    // ВЕБ-ОВЕРЛЕЙ
    @State private var webWC: WebOverlayController?
    @State private var webURL: String = "https://www.youtube.com/watch?v=dQw4w9WgXcQ"
    @State private var webClickThrough: Bool = false

    var body: some View {
        VStack(spacing: 18) {
            Text("On-Top Tools").font(.title2).bold()

            // ===== CAMERA =====
            GroupBox("Камера (фронталка) поверх всех окон") {
                HStack {
                    Button(cameraRunning ? "Stop camera" : "Start camera") {
                        if cameraRunning {
                            cameraWC?.close(); cameraWC = nil
                            camera.stop()
                            cameraRunning = false
                        } else {
                            AVCaptureDevice.requestAccess(for: .video) { granted in
                                DispatchQueue.main.async {
                                    guard granted else { return }
                                    camera.start()
                                    cameraWC = OverlayWindowController(session: camera.session)
                                    cameraRunning = true
                                }
                            }
                        }
                    }
                    Spacer()
                }
            }

            // ===== WINDOW MIRROR =====
            GroupBox("Зеркалить окно (ScreenCaptureKit)") {
                HStack {
                    Button(mirroring ? "Stop mirroring" : "Pick window & start") {
                        if mirroring {
                            Task { @MainActor in
                                mirror.stop()
                                mirrorWC?.close(); mirrorWC = nil
                                mirroring = false
                            }
                        } else {
                            Task { @MainActor in
                                await mirror.pickAndStart()
                                mirrorWC = OverlayWindowController(
                                    layer: mirror.displayLayer,
                                    title: "Window Mirror",
                                    aspect: mirror.sourceAspect
                                )
                                mirroring = true
                            }
                        }
                    }
                    Spacer()
                }
            }

            // ===== WEB OVERLAY =====
            GroupBox("Веб-оверлей (YouTube / TradingView без mirroring)") {
                VStack(alignment: .leading, spacing: 8) {
                    HStack(spacing: 8) {
                        TextField("Вставь URL…", text: $webURL)
                            .textFieldStyle(.roundedBorder)
                            .frame(minWidth: 320)

                        Button(webWC == nil ? "Open overlay" : "Close overlay") {
                            if webWC == nil {
                                let s = webURL.hasPrefix("http") ? webURL : "https://\(webURL)"
                                if let u = URL(string: s) {
                                    webWC = WebOverlayController(url: u, title: "Web Overlay")
                                    webWC?.setClickThrough(webClickThrough)
                                }
                            } else {
                                webWC?.close()
                                webWC = nil
                            }
                        }
                    }

                    Toggle("Сделать «клик-сквозь»...", isOn: $webClickThrough)
                        .onChange(of: webClickThrough) { _, newValue in
                            webWC?.setClickThrough(newValue)
                        }

                    HStack {
                        Button("Demo: YouTube") {
                            webURL = "https://www.youtube.com/watch?v=dQw4w9WgXcQ"
                        }
                        Button("Demo: TradingView") {
                            webURL = "https://www.tradingview.com/chart/"
                        }
                    }
                    .buttonStyle(.link)
                }
            }

            Text("Окна отображаются поверх всего и во всех Spaces (вкл. фуллскрин).")
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .padding(20)
        .frame(width: 520)
        .onDisappear {
            cameraWC?.close(); camera.stop()
            Task { @MainActor in mirror.stop(); mirrorWC?.close() }
            webWC?.close(); webWC = nil
        }
    }
}
