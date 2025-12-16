import Foundation
import AppKit
import AVFoundation
import ScreenCaptureKit

// NSView-хост для AVSampleBufferDisplayLayer
final class LayerHostView: NSView {
    let displayLayer: AVSampleBufferDisplayLayer
    
    override var mouseDownCanMoveWindow: Bool { true }   // ← перетаскивать окно за любой участок

    init(sampleLayer: AVSampleBufferDisplayLayer) {
        self.displayLayer = sampleLayer
        super.init(frame: .zero)
        wantsLayer = true
        if layer == nil { layer = CALayer() }
        layer?.backgroundColor = NSColor.clear.cgColor
        displayLayer.backgroundColor = NSColor.clear.cgColor
        displayLayer.videoGravity = .resizeAspectFill  //.resizeAspect    // под аспект
        layer?.addSublayer(displayLayer)
    }

    required init?(coder: NSCoder) { fatalError() }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        // если окно переехало на другой дисплей — обновим scale
        if let scale = window?.backingScaleFactor {
            displayLayer.contentsScale = scale
        }
    }

    override func layout() {
        super.layout()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        displayLayer.frame = bounds
        CATransaction.commit()
    }
}

// Захват произвольного окна через ScreenCaptureKit
final class WindowMirror: NSObject, SCStreamOutput {
    let displayLayer = AVSampleBufferDisplayLayer()
    @MainActor private(set) var sourceAspect: CGFloat = 16.0/9.0

    private var stream: SCStream?
    private var filter: SCContentFilter?
    private let outputQueue = DispatchQueue(label: "window.mirror.output")
    
    @MainActor private var targetAppBundleID: String?
    @MainActor private var targetWindowTitle: String?
    @MainActor private var targetWindowID: CGWindowID?
    @MainActor private var lastFrameAt: Date = .distantPast
    @MainActor private var monitor: DispatchSourceTimer?

    @MainActor
    func pickAndStart() async {
        print("[Mirror] pick: click the window you want within 3s…")
        stop()
        DispatchQueue.main.asyncAfter(deadline: .now() + 3.0) { [weak self] in
            Task { @MainActor in await self?.startFromFrontmostWindow() }
        }
    }

    @MainActor
    private func startFromFrontmostWindow() async {
        do {
            let content = try await SCShareableContent.current
            guard
                let wid = topmostNonSelfWindowID(),
                let win = content.windows.first(where: { $0.windowID == wid })
            else { print("[Mirror] could not find frontmost window match"); return }
            
            // запоминаем мишень
            targetAppBundleID  = win.owningApplication?.bundleIdentifier
            targetWindowTitle  = win.title
            targetWindowID     = win.windowID

            let f = win.frame
            self.sourceAspect = max(win.frame.width, 1) / max(win.frame.height, 1)

            let filter = SCContentFilter(desktopIndependentWindow: win)
            try await start(with: filter)
            
            startMonitoring() // <<< запускаем вотчер
        } catch {
            print("[Mirror] startFromFrontmostWindow failed:", error)
        }
    }

    @MainActor
    private func start(with filter: SCContentFilter) async throws {
        stop()
        self.filter = filter

        let cfg = SCStreamConfiguration()
        cfg.capturesAudio = false
        cfg.scalesToFit = true
        cfg.showsCursor = true
        cfg.width  = 1280
        cfg.height = 720

        let stream = SCStream(filter: filter, configuration: cfg, delegate: nil)
        try stream.addStreamOutput(self, type: .screen, sampleHandlerQueue: outputQueue)
        try await stream.startCapture()
        self.stream = stream

        print("[Mirror] started")
    }
    
    // Берём верхнее НЕ наше окно через CGWindowList
    private func topmostNonSelfWindowID() -> CGWindowID? {
        let options: CGWindowListOption = [.optionOnScreenOnly, .excludeDesktopElements]
        guard
            let list = CGWindowListCopyWindowInfo(options, kCGNullWindowID) as? [[String: Any]]
        else { return nil }

        let myPID = pid_t(getpid())
        for info in list {
            let layer = info[kCGWindowLayer as String] as? Int ?? 0
            guard layer == 0 else { continue } // только «обычные» окна
            let pid = info[kCGWindowOwnerPID as String] as? pid_t ?? 0
            guard pid != myPID else { continue } // пропускаем наше приложение
            let alpha = info[kCGWindowAlpha as String] as? Double ?? 1.0
            guard alpha > 0.01 else { continue }
            if let wid = info[kCGWindowNumber as String] as? CGWindowID {
                return wid
            }
        }
        return nil
    }
    
    
    @MainActor
    private func startMonitoring() {
        monitor?.cancel()
        let t = DispatchSource.makeTimerSource(queue: .main)
        t.schedule(deadline: .now() + 1.0, repeating: 0.8)
        t.setEventHandler { [weak self] in
            guard let self else { return }
            // если нет стрима — нечего делать
            guard self.stream != nil else { return }
            // если давно не было кадров — пробуем переподключиться
            if Date().timeIntervalSince(self.lastFrameAt) > 1.2 {
                Task { @MainActor in await self.reattachIfNeeded() }
            }
        }
        t.resume()
        monitor = t

        // + подстрахуемся на смену Spaces
        NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.activeSpaceDidChangeNotification,
            object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor in await self?.reattachIfNeeded() }
        }
    }

    @MainActor
    private func reattachIfNeeded() async {
        guard let bundleID = targetAppBundleID else { return }
        do {
            let content = try await SCShareableContent.current

            // 1) попытка: тот же windowID
            if let tid = targetWindowID,
               let same = content.windows.first(where: { $0.windowID == tid }) {
                // окно всё ещё существует — ничего не делаем
                return
            }

            // 2) попытка: по bundleID + совпадающему title
            if let title = targetWindowTitle,
               let w = content.windows.first(where: {
                   $0.owningApplication?.bundleIdentifier == bundleID && $0.title == title
               }) {
                targetWindowID = w.windowID
                let filter = SCContentFilter(desktopIndependentWindow: w)
                try await start(with: filter)
                print("[Mirror] reattached by title")
                return
            }

            // 3) fallback: верхнее окно того же приложения
            if let w = content.windows.first(where: { $0.owningApplication?.bundleIdentifier == bundleID }) {
                targetWindowTitle = w.title
                targetWindowID = w.windowID
                let filter = SCContentFilter(desktopIndependentWindow: w)
                try await start(with: filter)
                print("[Mirror] reattached by app")
                return
            }

            print("[Mirror] reattach failed: no matching window")
        } catch {
            print("[Mirror] reattach error:", error)
        }
    }
    

    /// Остановка
    @MainActor
    func stop() {
        monitor?.cancel()
        monitor = nil
        NotificationCenter.default.removeObserver(self, name: NSWorkspace.activeSpaceDidChangeNotification, object: nil)

        if let stream {
            stream.stopCapture { _ in }
            try? stream.removeStreamOutput(self, type: .screen)
        }
        stream = nil
        filter = nil
        displayLayer.sampleBufferRenderer.flush(removingDisplayedImage: true, completionHandler: {})
        print("[Mirror] stopped")
    }

    // MARK: - SCStreamOutput
    func stream(_ stream: SCStream,
                didOutputSampleBuffer sampleBuffer: CMSampleBuffer,
                of outputType: SCStreamOutputType) {
        guard outputType == .screen, CMSampleBufferIsValid(sampleBuffer) else { return }
        DispatchQueue.main.async { [displayLayer] in
            self.lastFrameAt = Date()                  // <<< фиксируем время последнего кадра
            displayLayer.sampleBufferRenderer.enqueue(sampleBuffer)
        }
    }

    func stream(_ stream: SCStream, didStopWithError error: Error) {
        print("[Mirror] stream stopped with error:", error)
    }
}
