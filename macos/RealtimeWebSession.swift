import AppKit
import WebKit

@MainActor
final class RealtimeWebSession: NSObject, ObservableObject, WKNavigationDelegate, WKUIDelegate, WKScriptMessageHandler, WKScriptMessageHandlerWithReply {
    @Published private(set) var hasVideo = false
    @Published private(set) var hasLocalVideo = false
    var releaseCamera: (() async -> Void)?
    var resumeCamera: (() -> Void)?
    private var ownsCamera = false
    @Published private(set) var needsLogin = false
    private var pageTask: Task<Void, Never>?
    private var sawBlackVideo = false
    private var lastServiceStatus: String?
    @Published private(set) var status: String?
    private let origin = URL(string: "https://try-on.apps.viceme.ai/")!
    private var pending: (data: Data, name: String, type: String)?
    @Published private(set) var isBusy = false
    private weak var window: NSWindow?
    private let bridge = "tryOnNative"

    lazy var view: WKWebView = {
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .default()
        configuration.mediaTypesRequiringUserActionForPlayback = []
        configuration.userContentController.add(self, name: bridge)
        configuration.userContentController.addScriptMessageHandler(self, contentWorld: .page, name: "tryOnCameraHandoff")
        let view = WKWebView(frame: .zero, configuration: configuration)
        view.navigationDelegate = self
        view.uiDelegate = self
        view.underPageBackgroundColor = .clear
        return view
    }()

    func start(image: URL, type: String, in window: NSWindow) {
        do {
            let size = try image.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
            guard (1...8_388_608).contains(size) else {
                status = "Choose an image up to 8 MB."
                return
            }
            let data = try Data(contentsOf: image)
            guard data.count <= 8_388_608 else {
                status = "Choose an image up to 8 MB."
                return
            }
            pending = (data, image.lastPathComponent, type)
        } catch {
            status = "Could not read the image."
            return
        }
        self.window = window
        hasVideo = false
        hasLocalVideo = false
        needsLogin = false
        sawBlackVideo = false
        lastServiceStatus = nil
        isBusy = true
        status = "Connecting…"
        view.load(URLRequest(url: origin, timeoutInterval: 20))
    }

    func webView(_ webView: WKWebView, decidePolicyFor action: WKNavigationAction,
                 decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
        let url = action.request.url
        decisionHandler(url?.scheme == "https" && url?.host == origin.host ? .allow : .cancel)
    }

    func webView(_ webView: WKWebView, decidePolicyFor response: WKNavigationResponse,
                 decisionHandler: @escaping (WKNavigationResponsePolicy) -> Void) {
        if response.isForMainFrame, let http = response.response as? HTTPURLResponse,
           !(200..<300).contains(http.statusCode) {
            if isBusy { finish("Try-on page returned HTTP \(http.statusCode).") }
            decisionHandler(.cancel)
        } else {
            decisionHandler(.allow)
        }
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        guard isBusy, webView.url?.host == origin.host else { return }
        guard pending != nil else {
            finish(hasVideo ? "Session ended." : noVideoMessage)
            return
        }
        pageTask?.cancel()
        pageTask = Task { await waitForTryOnPage() }
    }

    func cancelLogin() {
        guard needsLogin else { return }
        finish("Sign-in canceled.")
        view.stopLoading()
    }

    private func waitForTryOnPage() async {
        var deadline = ContinuousClock.now.advanced(by: .seconds(15))
        do {
            while !Task.isCancelled, let image = pending {
                let state = try await view.evaluateJavaScript(Self.pageStateScript) as? String
                guard !Task.isCancelled else { return }
                if state == "try-on" {
                    needsLogin = false
                    status = "Connecting…"
                    _ = try await view.callAsyncJavaScript(
                        Self.startScript,
                        arguments: [
                            "base64": image.data.base64EncodedString(), "name": image.name, "type": image.type,
                            "cameraScale": PreviewLayout.cameraScale, "previewGap": PreviewLayout.inset
                        ],
                        in: nil, contentWorld: .page
                    )
                    return
                }
                if state == "login" {
                    if !needsLogin { needsLogin = true }
                    deadline = .now.advanced(by: .seconds(15))
                } else if .now >= deadline {
                    finish("Try-on page did not load.")
                    return
                }
                try await Task.sleep(for: .milliseconds(300))
            }
        } catch {
            if !Task.isCancelled, isBusy, !view.isLoading { finish("Could not open the try-on page.") }
        }
    }

    private var noVideoMessage: String {
        let summary = sawBlackVideo ? "Try-on returned only black frames." : "Session ended before try-on video arrived."
        return lastServiceStatus.map { summary + " " + $0 } ?? summary
    }

    private func finish(_ message: String) {
        pending = nil
        pageTask?.cancel()
        pageTask = nil
        needsLogin = false
        isBusy = false
        hasVideo = false
        hasLocalVideo = false
        status = message
        if ownsCamera {
            ownsCamera = false
            view.setCameraCaptureState(.none) { [weak self] in
                self?.resumeCamera?()
            }
        }
    }

    func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
        if isBusy { finish("Try-on browser process stopped.") }
    }

    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        if isBusy && (error as NSError).code != NSURLErrorCancelled {
            finish("Could not connect to try-on.")
        }
    }

    func webView(_ webView: WKWebView, requestMediaCapturePermissionFor source: WKSecurityOrigin,
                 initiatedByFrame frame: WKFrameInfo, type: WKMediaCaptureType,
                 decisionHandler: @escaping (WKPermissionDecision) -> Void) {
        guard isBusy, frame.isMainFrame, source.protocol == "https",
              source.host == origin.host, type == .camera else {
            decisionHandler(.deny)
            return
        }
        decisionHandler(ownsCamera ? .grant : .deny)
    }

    func userContentController(_ controller: WKUserContentController, didReceive message: WKScriptMessage,
                               replyHandler: @escaping (Any?, String?) -> Void) {
        guard isBusy, pending != nil, message.frameInfo.isMainFrame,
              message.frameInfo.securityOrigin.host == origin.host else {
            replyHandler(nil, "Camera handoff is unavailable.")
            return
        }
        // Login can replace the page while preflight is still running. Keep
        // the selected image available until the actual session is starting.
        pending = nil
        ownsCamera = true
        Task {
            await releaseCamera?()
            if isBusy { replyHandler(true, nil) }
            else { replyHandler(nil, "Session ended.") }
        }
    }

    func userContentController(_ controller: WKUserContentController, didReceive message: WKScriptMessage) {
        guard isBusy, message.frameInfo.isMainFrame,
              message.frameInfo.securityOrigin.host == origin.host,
              let event = message.body as? String else { return }
        switch event {
        case "local":
            hasLocalVideo = true
        case "frame":
            status = nil
            hasVideo = true
        case "black":
            sawBlackVideo = true
        case "ended":
            finish(hasVideo ? "Session ended." : noVideoMessage)
        default:
            if event.hasPrefix("status:") {
                lastServiceStatus = String(event.dropFirst(7).prefix(150))
                if !hasVideo { status = lastServiceStatus }
            } else {
                finish(event)
            }
        }
    }

    private static let pageStateScript = """
    document.querySelector('form input[type=password][name=password]') ? 'login' :
    document.querySelector('input[type=file][accept*="image/webp"]:not([capture])') ? 'try-on' : 'loading'
    """

    private static let startScript = """
    const tell = message => window.webkit.messageHandlers.tryOnNative.postMessage(message);
    const until = async (get, timeout = 8000) => {
        const deadline = performance.now() + timeout;
        while (performance.now() < deadline) {
            const value = get();
            if (value) return value;
            await new Promise(resolve => setTimeout(resolve, 100));
        }
        return null;
    };
    const controls = () => {
        const buttons = [...document.querySelectorAll('button')];
        const findButton = pattern => buttons.find(button =>
            pattern.test((button.getAttribute('aria-label') || button.textContent).trim()));
        return {
            input: document.querySelector('input[type=file][accept*="image/webp"]:not([capture])'),
            start: findButton(/^(?:Start 30[-– ]second try[- ]on|开始\\s*30\\s*秒试穿)$/i),
            local: document.querySelector('video[aria-label="Local camera"], video[aria-label="本机摄像头"]'),
            video: document.querySelector('video[aria-label="Decart output"], video[aria-label="Decart 输出"]')
        };
    };
    const ready = await until(() => {
        const current = controls();
        return Object.values(current).every(Boolean) ? current : null;
    }, 15000);
    if (!ready) {
        const missing = Object.entries(controls()).filter(([, element]) => !element).map(([key]) => key);
        tell('Try-on page did not load: ' + missing.join(', ') + '.');
        return;
    }
    const {input, local, video} = ready;
    const stopButton = () => [...document.querySelectorAll('button')].find(button =>
        /^(?:Stop(?:\\s|$)|停止|结束)/i.test((button.getAttribute('aria-label') || button.textContent).trim()));
    const bytes = Uint8Array.from(atob(base64), character => character.charCodeAt(0));
    const transfer = new DataTransfer();
    transfer.items.add(new File([bytes], name, {type}));
    input.files = transfer.files;
    input.dispatchEvent(new Event('change', {bubbles: true}));
    const start = await until(() => {
        const button = controls().start;
        return button && !button.disabled ? button : null;
    });
    if (!start) {
        tell('Try-on could not start. Check the image and service status.');
        return;
    }

    // Mirror the site's media streams in a top-level layer so page layout and
    // stacking contexts cannot clip the videos inside the native window.
    const style = document.createElement('style');
    style.textContent = `
        html,body {background:transparent!important;overflow:hidden!important}
        body > :not(#native-stage) {visibility:hidden!important}
        #native-stage {position:fixed;inset:0;z-index:2147483647;pointer-events:none}
        #native-stage video {position:absolute;display:block;object-fit:cover;background:black;
            width:100%;height:100%;inset:0;border-radius:15px;visibility:hidden}
        #native-stage .visible {visibility:visible}
        #native-stage:not(.result) .local {transform:scaleX(-1)}
        #native-stage.result {display:grid;grid-template-columns:minmax(0,1fr) minmax(0,${cameraScale}fr);
            grid-template-rows:minmax(0,1fr);column-gap:${previewGap}px;align-items:start}
        #native-stage.result video {position:static}
        #native-stage.result .output {grid-column:1;grid-row:1}
        #native-stage.result .local {grid-column:2;grid-row:1;height:calc(100% * ${cameraScale})}
    `;
    document.head.append(style);
    const stage = document.createElement('div');
    stage.id = 'native-stage';
    document.body.append(stage);
    const mirror = (source, name) => {
        const display = document.createElement('video');
        display.className = name;
        display.muted = true;
        display.playsInline = true;
        display.autoplay = true;
        stage.append(display);
        return () => {
            if (display.srcObject !== source.srcObject) {
                display.srcObject = source.srcObject;
                if (display.srcObject) display.play().catch(() => {});
            }
            return display;
        };
    };
    const showLocal = mirror(local, 'local');
    const showOutput = mirror(video, 'output');
    const sample = document.createElement('canvas');
    sample.width = sample.height = 24;
    const pixels = sample.getContext('2d', {willReadFrequently:true});
    let receivedFrame = false, cameraReady = false, reportedBlack = false;
    let lastFrame = 0, previousStatus = '', lastVideoTime = -1;
    const inspectFrame = (output, now) => {
        if (output.readyState < 2 || !output.videoWidth || output.currentTime === lastVideoTime) return;
        lastVideoTime = output.currentTime;
        if (!receivedFrame && pixels) {
            try {
                pixels.drawImage(output, 0, 0, 24, 24);
                const rgba = pixels.getImageData(0, 0, 24, 24).data;
                let lit = 0;
                for (let i = 0; i < rgba.length; i += 4) {
                    if (Math.max(rgba[i], rgba[i+1], rgba[i+2]) > 18) lit++;
                }
                if (lit < 8) {
                    if (!reportedBlack) { reportedBlack = true; tell('black'); }
                    return;
                }
            } catch {
                // A decoded frame is still usable if WebKit disallows pixel readback.
            }
        }
        if (!receivedFrame) {
            receivedFrame = true;
            stage.classList.add('result');
            output.classList.add('visible');
            tell('frame');
        }
        lastFrame = now;
    };
    await window.webkit.messageHandlers.tryOnCameraHandoff.postMessage(null);
    start.click();
    const began = performance.now();
    const watchdog = setInterval(() => {
        const now = performance.now();
        inspectFrame(showOutput(), now);
        const localDisplay = showLocal();
        if (!cameraReady && localDisplay.readyState >= 2 && localDisplay.videoWidth) {
            cameraReady = true;
            localDisplay.classList.add('visible');
            tell('local');
        }
        const state = document.querySelector('[role="status"]')?.textContent.trim();
        if (state && state !== previousStatus) {
            previousStatus = state;
            tell('status:' + state);
        }
        const localEnded = cameraReady && !localDisplay.srcObject?.getVideoTracks().some(track => track.readyState === 'live');
        if (localEnded || (receivedFrame && now - lastFrame > 6000) || now - began > 37000) {
            clearInterval(watchdog);
            const stop = stopButton();
            if (stop && !stop.disabled) stop.click();
            tell('ended');
        }
    }, 150);
    """
}
