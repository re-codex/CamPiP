import SwiftUI
import AVFoundation
import AppKit

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
        // рамка/скругления — по желанию
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
final class OverlayWindowController: NSWindowController {
    private var hostView: CameraPreviewView?

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

        // ВАЖНО: уровень окна. Для «поверх всего», включая фуллскрины, начни со .screenSaver
        panel.level = .screenSaver
        // Если слишком агрессивно — попробуй .popUpMenu или .statusBar
        // panel.level = .popUpMenu

        panel.title = "SelfView"
        panel.titleVisibility = .hidden
        panel.titlebarAppearsTransparent = true

        panel.isFloatingPanel = true
        panel.hidesOnDeactivate = false
        panel.collectionBehavior = [.canJoinAllSpaces, .ignoresCycle, .stationary]
        panel.isMovableByWindowBackground = true
        panel.isOpaque = false
        panel.backgroundColor = .windowBackgroundColor
        panel.hasShadow = true

        let view = CameraPreviewView(session: session)
        view.autoresizingMask = [.width, .height]
        panel.contentView = view
        self.hostView = view

        super.init(window: panel)
        window?.makeKeyAndOrderFront(nil)
    }
    required init?(coder: NSCoder) { fatalError() }
}

// MARK: - SwiftUI UI (как у тебя)
struct ContentView: View {
    @State private var capture = CameraCapture()
    @State private var overlayWC: OverlayWindowController?
    @State private var running = false

    var body: some View {
        VStack(spacing: 12) {
            Text("Mirror On Top").font(.title2).bold()
            HStack(spacing: 12) {
                Button(running ? "Stop" : "Start") {
                    if running {
                        overlayWC?.close(); overlayWC = nil
                        capture.stop()
                        running = false
                    } else {
                        AVCaptureDevice.requestAccess(for: .video) { granted in
                            DispatchQueue.main.async {
                                guard granted else { return }
                                capture.start()
                                overlayWC = OverlayWindowController(session: capture.session)
                                running = true
                            }
                        }
                    }
                }
                .keyboardShortcut(.space, modifiers: [])

                if running {
                    Button("Snap to corner") {
                        if let win = overlayWC?.window, let screen = win.screen?.visibleFrame {
                            let sz = win.frame.size
                            win.setFrameOrigin(.init(x: screen.maxX - sz.width - 24, y: screen.minY + 24))
                        }
                    }
                }
            }

            Text("Окно камеры закреплено поверх всех окон\nи видно во всех Spaces (в т.ч. фуллскрин).")
                .multilineTextAlignment(.center)
                .foregroundStyle(.secondary)
        }
        .padding(20)
        .frame(width: 380, height: 160)
        .onDisappear { overlayWC?.close(); capture.stop() }
    }
}
