import AppKit
@preconcurrency import AVFoundation
import SwiftUI
import UniformTypeIdentifiers
import WebKit

private final class UploadPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }

    override func cancelOperation(_ sender: Any?) {
        close()
    }
}

private struct CameraPreview: NSViewRepresentable {
    let session: AVCaptureSession

    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        let preview = AVCaptureVideoPreviewLayer(session: session)
        preview.videoGravity = .resizeAspectFill
        view.wantsLayer = true
        view.layer = preview
        return view
    }

    func updateNSView(_ view: NSView, context: Context) {}
}

private struct ServicePreview: NSViewRepresentable {
    let webView: WKWebView

    func makeNSView(context: Context) -> WKWebView { webView }
    func updateNSView(_ view: WKWebView, context: Context) {}
}

private enum PreviewLayout {
    static let width: CGFloat = 544
    static let aspect: CGFloat = 4.0 / 3.0
    static let inset: CGFloat = 12

    static let cameraScale: CGFloat = 0.42

    static func windowSize(showOutput: Bool, on screen: NSScreen?) -> NSSize {
        let stackScale = showOutput ? 1 + cameraScale : 1
        let margins = (showOutput ? 3 : 2) * inset
        let bounds = screen?.visibleFrame.size ?? NSSize(width: 1440, height: 900)
        let tileWidth = floor(min(width, bounds.width - 4 * inset,
                                  (bounds.height - margins - 2 * inset) * aspect / stackScale))
        return NSSize(width: tileWidth + 2 * inset, height: tileWidth / aspect * stackScale + margins)
    }
}

private struct UploadView: View {
    private static let logo = Bundle.main.url(forResource: "mirra-logo", withExtension: "png")
        .flatMap { NSImage(contentsOf: $0) }

    @State private var selectedFile: URL?
    @ObservedObject var service: RealtimeWebSession
    let session: AVCaptureSession
    let cameraMessage: String?
    let chooseImage: (@escaping (URL) -> Void) -> Void
    let resize: (Bool) -> Void
    let close: () -> Void

    var body: some View {
        GeometryReader { geometry in
            let hasVideo = service.hasVideo
            let stackScale = hasVideo ? 1 + PreviewLayout.cameraScale : 1
            let margins = (hasVideo ? 3 : 2) * PreviewLayout.inset
            let width = min(PreviewLayout.width,
                            max(0, geometry.size.width - 2 * PreviewLayout.inset),
                            max(0, geometry.size.height - margins) * PreviewLayout.aspect / stackScale)
            let height = width / PreviewLayout.aspect
            ZStack {
                ServicePreview(webView: service.view)
                    .frame(width: width, height: height * stackScale + (hasVideo ? PreviewLayout.inset : 0))
                    .allowsHitTesting(false)
                    .accessibilityHidden(true)
                VStack(spacing: PreviewLayout.inset) {
                    if hasVideo {
                        tile("Try On", width: width) { Color.clear }
                        camera(width: width * PreviewLayout.cameraScale)
                    } else {
                        camera(width: width)
                    }
                }
            }
            .clipShape(.rect(cornerRadius: 15))
            .overlay(alignment: .bottomTrailing) {
                if hasVideo, let logo = Self.logo {
                    Image(nsImage: logo)
                        .resizable()
                        .scaledToFit()
                        .frame(width: min(112, width * 0.21))
                        .padding(10)
                        .allowsHitTesting(false)
                        .accessibilityHidden(true)
                }
            }
            .padding(PreviewLayout.inset)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .onChange(of: service.hasVideo) { _, visible in resize(visible) }
        .onExitCommand(perform: close)
    }

    private func camera(width: CGFloat) -> some View {
        tile("Camera", width: width) {
            ZStack {
                if !service.hasLocalVideo {
                    Color.black
                    CameraPreview(session: session)
                }
                if let message = service.status ?? cameraMessage {
                    Text(message)
                        .font(.callout)
                        .multilineTextAlignment(.center)
                        .foregroundStyle(.white)
                        .padding(8)
                        .background(.black.opacity(0.65), in: .rect(cornerRadius: 8))
                }
            }
            .overlay(alignment: .bottom) {
                Button("Upload") {
                    chooseImage { selectedFile = $0 }
                }
                .buttonStyle(.glass)
                .keyboardShortcut("o", modifiers: .command)
                .disabled(service.isBusy)
                .accessibilityValue(selectedFile?.lastPathComponent ?? "")
                .help("Choose an image and start a try-on session")
                .padding(12)
            }
        }
    }

    private func tile<Content: View>(
        _ label: String,
        width: CGFloat,
        @ViewBuilder content: () -> Content
    ) -> some View {
        content()
            .frame(width: width, height: width / PreviewLayout.aspect)
            .clipShape(.rect(cornerRadius: 15))
            .overlay(alignment: .topLeading) {
                Text(label)
                    .font(.caption.weight(.semibold))
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(.regularMaterial, in: Capsule())
                    .padding(8)
            }

    }
}

@MainActor
private final class UploadApp: NSObject, NSApplicationDelegate, NSWindowDelegate {
    private var panel: UploadPanel?
    private var host: NSHostingView<UploadView>?
    private let session = AVCaptureSession()
    private let cameraQueue = DispatchQueue(label: "local.tryon.camera", qos: .userInitiated)
    private let service = RealtimeWebSession()
    private var cameraMessage: String? = "Starting camera…"

    private func rootView() -> UploadView {
        UploadView(
            service: service,
            session: session,
            cameraMessage: cameraMessage,
            chooseImage: { [weak self] completion in self?.chooseImage(completion) },
            resize: { [weak self] visible in self?.resizeWindow(showOutput: visible) },
            close: { [weak self] in self?.panel?.close() }
        )
    }

    private func resizeWindow(showOutput: Bool) {
        guard let panel else { return }
        let screen = panel.screen ?? NSScreen.main
        var frame = panel.frame
        frame.size = PreviewLayout.windowSize(showOutput: showOutput, on: screen)
        frame.origin.y = panel.frame.maxY - frame.height
        if let bounds = screen?.visibleFrame {
            frame.origin.x = max(bounds.minX, min(frame.minX, bounds.maxX - frame.width - 12))
            frame.origin.y = max(bounds.minY, frame.minY)
        }
        panel.setFrame(frame, display: true)
    }

    private func updateCameraMessage(_ message: String?) {
        cameraMessage = message
        host?.rootView = rootView()
    }

    private func startCamera() async {
        guard await AVCaptureDevice.requestAccess(for: .video) else {
            updateCameraMessage("Allow camera access in System Settings.")
            return
        }
        let session = session
        cameraQueue.async { [weak self] in
            if session.inputs.isEmpty {
                guard let device = AVCaptureDevice.default(for: .video),
                      let input = try? AVCaptureDeviceInput(device: device),
                      session.canAddInput(input) else {
                    Task { @MainActor in self?.updateCameraMessage("Camera unavailable.") }
                    return
                }
                session.addInput(input)
            }
            session.startRunning()
            let message = session.isRunning ? nil : "Camera unavailable."
            Task { @MainActor in self?.updateCameraMessage(message) }
        }
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        service.releaseCamera = { [weak self] in
            guard let self else { return }
            let session = self.session
            await withCheckedContinuation { continuation in
                self.cameraQueue.async {
                    if session.isRunning { session.stopRunning() }
                    continuation.resume()
                }
            }
        }
        service.resumeCamera = { [weak self] in
            Task { await self?.startCamera() }
        }
        let size = PreviewLayout.windowSize(showOutput: false, on: NSScreen.main)
        let panel = UploadPanel(
            contentRect: NSRect(origin: .zero, size: size),
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        panel.title = "Try On"
        panel.identifier = NSUserInterfaceItemIdentifier("tryon.upload")
        panel.delegate = self
        panel.isReleasedWhenClosed = false
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.isFloatingPanel = true
        panel.level = .floating
        panel.hidesOnDeactivate = false
        panel.isMovableByWindowBackground = true
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]

        let blur = NSVisualEffectView(frame: panel.contentRect(forFrameRect: panel.frame))
        blur.material = .popover
        blur.blendingMode = .behindWindow
        blur.state = .active
        blur.wantsLayer = true
        blur.layer?.cornerRadius = 26
        blur.layer?.cornerCurve = .continuous
        blur.layer?.masksToBounds = true

        let host = NSHostingView(rootView: rootView())
        self.host = host
        host.frame = blur.bounds
        host.autoresizingMask = [.width, .height]
        blur.addSubview(host)
        panel.contentView = blur
        self.panel = panel

        installMenu()
        if let screen = NSScreen.main {
            let bounds = screen.visibleFrame
            panel.setFrameOrigin(NSPoint(x: bounds.maxX - size.width - 24, y: bounds.maxY - size.height - 24))
        } else {
            panel.center()
        }
        NSApp.activate()
        panel.makeKeyAndOrderFront(nil)
        Task { await startCamera() }
    }

    func windowWillClose(_ notification: Notification) {
        NSApp.terminate(nil)
    }

    private func installMenu() {
        let mainMenu = NSMenu()
        let appItem = NSMenuItem()
        let appMenu = NSMenu()
        appMenu.addItem(withTitle: "Quit Try On", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        appItem.submenu = appMenu
        mainMenu.addItem(appItem)

        let windowItem = NSMenuItem()
        let windowMenu = NSMenu(title: "Window")
        windowMenu.addItem(withTitle: "Close", action: #selector(NSWindow.performClose(_:)), keyEquivalent: "w")
        windowItem.submenu = windowMenu
        mainMenu.addItem(windowItem)
        NSApp.mainMenu = mainMenu
    }

    private func chooseImage(_ completion: @escaping (URL) -> Void) {
        guard let panel, panel.attachedSheet == nil else { return }
        let picker = NSOpenPanel()
        picker.title = "Choose a Garment Image"
        picker.prompt = "Start Try-On"
        picker.message = "Choosing an image starts a paid 30-second session and sends the image and live camera video to Decart."
        picker.allowedContentTypes = [.jpeg, .png, .webP]
        picker.canChooseDirectories = false
        picker.beginSheetModal(for: panel) { response in
            if response == .OK, let url = picker.url {
                completion(url)
                let mime = (try? url.resourceValues(forKeys: [.contentTypeKey]))?.contentType?.preferredMIMEType
                self.service.start(image: url, type: mime ?? "application/octet-stream", in: panel)
            }
        }
    }
}

@main
enum TryOn {
    @MainActor
    static func main() {
        let app = NSApplication.shared
        let delegate = UploadApp()
        app.delegate = delegate
        app.setActivationPolicy(.regular)
        app.run()
        withExtendedLifetime(delegate) {}
    }
}
