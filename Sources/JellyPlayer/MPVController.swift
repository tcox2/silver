import AppKit
import Darwin
import QuartzCore

@MainActor
final class MPVController {
    private typealias Create = @convention(c) () -> OpaquePointer?
    private typealias Initialize = @convention(c) (OpaquePointer?) -> Int32
    private typealias SetString = @convention(c) (OpaquePointer?, UnsafePointer<CChar>, UnsafePointer<CChar>) -> Int32
    private typealias Command = @convention(c) (OpaquePointer?, UnsafePointer<UnsafePointer<CChar>?>) -> Int32
    private typealias GetString = @convention(c) (OpaquePointer?, UnsafePointer<CChar>) -> UnsafeMutablePointer<CChar>?
    private typealias Free = @convention(c) (UnsafeMutableRawPointer?) -> Void
    private typealias Destroy = @convention(c) (OpaquePointer?) -> Void
    private typealias RequestLogMessages = @convention(c) (OpaquePointer?, UnsafePointer<CChar>) -> Int32
    private typealias WaitEvent = @convention(c) (OpaquePointer?, Double) -> UnsafeRawPointer?
    private typealias RenderCreate = @convention(c) (UnsafeMutableRawPointer?, OpaquePointer?, UnsafeMutableRawPointer?) -> Int32
    private typealias RenderFrame = @convention(c) (OpaquePointer?, UnsafeMutableRawPointer?) -> Void
    private typealias RenderUpdate = @convention(c) (OpaquePointer?) -> UInt64
    private typealias RenderReportSwap = @convention(c) (OpaquePointer?) -> Void
    private typealias RenderSetUpdate = @convention(c) (OpaquePointer?, (@convention(c) (UnsafeMutableRawPointer?) -> Void)?, UnsafeMutableRawPointer?) -> Void
    private typealias RenderFree = @convention(c) (OpaquePointer?) -> Void

    private var library: UnsafeMutableRawPointer?
    private var handle: OpaquePointer?
    private var pendingURL: URL?
    private var attached = false
    private var eventLoopRunning = false
    private var renderContext: OpaquePointer?
    private var renderUpdate: RenderUpdate?
    private var renderReportSwap: RenderReportSwap?
    private weak var renderView: MPVOpenGLView?
    private(set) var attachmentError: Error?
    var playbackEnded: (() -> Void)?

    func attach(to view: MPVOpenGLView) throws {
        guard !attached else { return }
        let bundledPath = Bundle.main.privateFrameworksPath.map {
            URL(fileURLWithPath: $0).appendingPathComponent("libmpv.2.dylib").path
        }
        let jellyfinPath = "/Applications/Jellyfin Desktop.app/Contents/Frameworks/libmpv.2.dylib"
        let path = bundledPath.flatMap { FileManager.default.fileExists(atPath: $0) ? $0 : nil } ?? jellyfinPath
        SilverLog.info("Loading media runtime path=\(path)")
        guard let library = dlopen(path, RTLD_NOW | RTLD_LOCAL) else {
            let detail = dlerror().map { String(cString: $0) } ?? "unknown dyld error"
            SilverLog.error("Media runtime load failed dyld=\(detail)")
            throw MPVError.unavailable(detail)
        }
        self.library = library
        let create: Create = try symbol("mpv_create")
        guard let handle = create() else { throw MPVError.unavailable("mpv_create returned nil") }
        self.handle = handle
        try option("vo", "libmpv")
        try option("fullscreen", "yes")
        try option("border", "no")
        try option("hwdec", "no")
        try option("vd-lavc-threads", "16")
        // Compressed input is cheap to retain and absorbs network or Jellyfin
        // stalls. Decoded 4K P010 frames are much larger, so keep two seconds:
        // approximately 1 GiB at 3840x1920/24 fps, with padding headroom.
        try option("cache", "yes")
        try option("demuxer-max-bytes", "1GiB")
        try option("demuxer-max-back-bytes", "256MiB")
        try option("vd-queue-enable", "yes")
        try option("vd-queue-max-samples", "48")
        try option("vd-queue-max-bytes", "1536MiB")
        try option("vd-queue-max-secs", "2")
        try option("vid", "auto")
        try option("aid", "auto")
        try option("sid", "auto")
        try option("keep-open", "yes")
        try option("terminal", "no")
        // Synchronize fractional cinema material to the verified integer HDMI
        // display clock. Audio is resampled by mpv to preserve A/V alignment.
        try option("video-sync", "display-resample")
        try option("video-sync-max-video-change", "1")
        let initialize: Initialize = try symbol("mpv_initialize")
        guard initialize(handle) >= 0 else { throw MPVError.initialization }
        try createRenderContext(for: view)
        startEventLogging()
        attached = true
        attachmentError = nil
        SilverLog.info("Media runtime initialized with 1GiB/256MiB demux cache, 48-frame/2-second/1536MiB decoder queue, and display-resample synchronization")
        if let pendingURL {
            do { try load(pendingURL); self.pendingURL = nil }
            catch {
                SilverLog.error("Playback engine load failed: \(error.localizedDescription)")
                throw error
            }
        }
    }

    func recordAttachmentFailure(_ error: Error) {
        attachmentError = error
    }

    func load(_ url: URL) throws {
        guard attached else {
            SilverLog.info("Media load queued until video surface is attached")
            pendingURL = url
            return
        }
        SilverLog.info("Sending direct-play URL to media runtime host=\(url.host ?? "unknown")")
        // Never let libmpv guess a subtitle track. The web UI either supplies
        // one exact Jellyfin SRT stream or explicitly selects subtitles off.
        try command(["set", "sid", "no"])
        try command(["loadfile", url.absoluteString, "replace"])
    }

    func addSubtitle(_ url: URL) throws {
        try command(["sub-add", url.absoluteString, "select"])
    }

    func stop() { try? command(["stop"]) }
    func setPaused(_ paused: Bool) throws {
        try command(["set", "pause", paused ? "yes" : "no"])
    }
    func configureDisplaySync(refreshRate: Double) throws {
        guard refreshRate.isFinite, refreshRate > 0 else { throw MPVError.displaySynchronization }
        try command(["set", "display-fps-override", String(format: "%.9f", refreshRate)])
        SilverLog.info("mpv display clock override configured refreshRate=\(String(format: "%.9f", refreshRate))")
    }
    func seek(to seconds: Double) throws { try command(["seek", String(seconds), "absolute+exact"]) }
    func prebufferSample() -> PlaybackPrebufferSample {
        PlaybackPrebufferSample(
            videoOutputConfigured: string("vo-configured") == "yes",
            videoFormatAvailable: string("video-format") != nil,
            decodedFrameRate: number("estimated-vf-fps"),
            position: number("time-pos"),
            demuxedSeconds: number("demuxer-cache-duration"),
            reachedEndOfFile: string("eof-reached") == "yes"
        )
    }
    func string(_ name: String) -> String? {
        guard let handle, let library else { return nil }
        let get = unsafeBitCast(dlsym(library, "mpv_get_property_string"), to: GetString.self)
        let free = unsafeBitCast(dlsym(library, "mpv_free"), to: Free.self)
        return name.withCString { key in
            guard let value = get(handle, key) else { return nil }
            defer { free(value) }
            return String(cString: value)
        }
    }
    func number(_ name: String) -> Double? { string(name).flatMap(Double.init) }

    private func option(_ name: String, _ value: String) throws {
        let setter: SetString = try symbol("mpv_set_option_string")
        let result = name.withCString { key in value.withCString { setter(handle, key, $0) } }
        if result < 0 { throw MPVError.option(name) }
    }

    private func command(_ values: [String]) throws {
        let function: Command = try symbol("mpv_command")
        let pointers = values.map { strdup($0) }
        defer { pointers.forEach { free($0) } }
        let args = pointers.map { UnsafePointer<CChar>($0) as UnsafePointer<CChar>? } + [nil]
        if args.withUnsafeBufferPointer({ function(handle, $0.baseAddress!) }) < 0 { throw MPVError.command }
    }

    private func symbol<T>(_ name: String) throws -> T {
        guard let library, let pointer = dlsym(library, name) else {
            throw MPVError.unavailable("missing symbol \(name)")
        }
        return unsafeBitCast(pointer, to: T.self)
    }

    private func startEventLogging() {
        guard let handle, let library, !eventLoopRunning else { return }
        let request = unsafeBitCast(dlsym(library, "mpv_request_log_messages"), to: RequestLogMessages.self)
        _ = "warn".withCString { request(handle, $0) }
        let wait = unsafeBitCast(dlsym(library, "mpv_wait_event"), to: WaitEvent.self)
        eventLoopRunning = true
        DispatchQueue.global(qos: .utility).async { [weak self] in
            while let self, self.eventLoopRunning {
                guard let rawEvent = wait(handle, 0.25) else { continue }
                let event = rawEvent.assumingMemoryBound(to: MPVEvent.self)
                // MPV_EVENT_LOG_MESSAGE = 2, MPV_EVENT_SHUTDOWN = 1,
                // MPV_EVENT_END_FILE = 7. Only a natural EOF should return
                // Silver to its idle display state; stop/replacement events
                // already use AppModel.stop().
                if event.pointee.eventID == 2, let data = event.pointee.data {
                    let message = data.assumingMemoryBound(to: MPVLogMessage.self).pointee
                    guard let text = message.text else { continue }
                    let raw = String(cString: text).trimmingCharacters(in: .whitespacesAndNewlines)
                    guard !raw.isEmpty else { continue }
                    let prefix = message.prefix.map(String.init(cString:)) ?? "mpv"
                    if raw.localizedCaseInsensitiveContains("api_key") || raw.contains("https://") || raw.contains("http://") || raw.contains("/Videos/") {
                        SilverLog.info("mpv[\(prefix)] [media request redacted]")
                    } else {
                        SilverLog.info("mpv[\(prefix)] \(raw)")
                    }
                } else if event.pointee.eventID == 7, let data = event.pointee.data {
                    let endFile = data.assumingMemoryBound(to: MPVEventEndFile.self).pointee
                    if endFile.reason == 0 {
                        SilverLog.info("Media runtime reported natural end of file")
                        DispatchQueue.main.async { [weak self] in
                            self?.playbackEnded?()
                        }
                    }
                } else if event.pointee.eventID == 1 {
                    break
                }
            }
        }
    }

    private func createRenderContext(for view: MPVOpenGLView) throws {
        guard let handle else { throw MPVError.initialization }
        view.openGLContext?.makeCurrentContext()
        var api = Array("opengl".utf8CString)
        var initParams = MPVOpenGLInitParams(getProcAddress: silverGLProcAddress, context: nil)
        var params: [MPVRenderParam] = api.withUnsafeMutableBufferPointer { apiBuffer in
            withUnsafeMutablePointer(to: &initParams) { initPointer in
                [
                    MPVRenderParam(type: 1, data: UnsafeMutableRawPointer(apiBuffer.baseAddress)),
                    MPVRenderParam(type: 2, data: UnsafeMutableRawPointer(initPointer)),
                    MPVRenderParam(type: 0, data: nil)
                ]
            }
        }
        let create: RenderCreate = try symbol("mpv_render_context_create")
        var context: OpaquePointer?
        let result = params.withUnsafeMutableBufferPointer { buffer in
            withUnsafeMutablePointer(to: &context) { contextPointer in
                create(UnsafeMutableRawPointer(contextPointer), handle, UnsafeMutableRawPointer(buffer.baseAddress))
            }
        }
        guard result >= 0,
              let context else { throw MPVError.renderContext }
        renderContext = context
        renderUpdate = try symbol("mpv_render_context_update")
        renderReportSwap = try symbol("mpv_render_context_report_swap")
        renderView = view
        view.controller = self
        let setUpdate: RenderSetUpdate = try symbol("mpv_render_context_set_update_callback")
        setUpdate(context, silverMPVRenderUpdate, Unmanaged.passUnretained(view).toOpaque())
    }

    func renderForDisplaySwap(width: Int32, height: Int32) {
        guard let context = renderContext, let library else { return }
        _ = renderUpdate?(context)
        var fbo = MPVOpenGLFBO(fbo: 0, width: width, height: height, internalFormat: 0)
        var flip: Int32 = 1
        var blockForTargetTime: Int32 = 0
        var params: [MPVRenderParam] = withUnsafeMutablePointer(to: &fbo) { fboPointer in
            withUnsafeMutablePointer(to: &flip) { flipPointer in
                withUnsafeMutablePointer(to: &blockForTargetTime) { timingPointer in
                    [
                        MPVRenderParam(type: 3, data: UnsafeMutableRawPointer(fboPointer)),
                        MPVRenderParam(type: 4, data: UnsafeMutableRawPointer(flipPointer)),
                        MPVRenderParam(type: 12, data: UnsafeMutableRawPointer(timingPointer)),
                        MPVRenderParam(type: 0, data: nil)
                    ]
                }
            }
        }
        let render = unsafeBitCast(dlsym(library, "mpv_render_context_render"), to: RenderFrame.self)
        params.withUnsafeMutableBufferPointer { render(context, UnsafeMutableRawPointer($0.baseAddress)) }
    }

    func reportDisplaySwap() {
        guard let context = renderContext else { return }
        renderReportSwap?(context)
    }

    func verifyDisplaySynchronization(sourceFrameRate: Double, outputRefreshRate: Double) -> Bool {
        let expectedCorrection = outputRefreshRate / sourceFrameRate
        let actualCorrection = number("video-speed-correction")
        let estimatedFPS = number("estimated-display-fps")
        let measuredFPS = renderView?.measuredRefreshRate
        let active = string("display-sync-active") == "yes"
        let correctionOK = actualCorrection.map { abs($0 - expectedCorrection) < 0.00035 } ?? false
        let estimatedOK = estimatedFPS.map { abs($0 - outputRefreshRate) < 0.05 } ?? false
        let measuredOK = measuredFPS.map { abs($0 - outputRefreshRate) < 0.05 } ?? false
        SilverLog.info(
            "Display synchronization verification active=\(active) " +
            "sourceFPS=\(String(format: "%.9f", sourceFrameRate)) " +
            "outputFPS=\(String(format: "%.9f", outputRefreshRate)) " +
            "measuredFPS=\(measuredFPS.map { String(format: "%.9f", $0) } ?? "nil") " +
            "estimatedFPS=\(estimatedFPS.map { String(format: "%.9f", $0) } ?? "nil") " +
            "expectedCorrection=\(String(format: "%.9f", expectedCorrection)) " +
            "actualCorrection=\(actualCorrection.map { String(format: "%.9f", $0) } ?? "nil")"
        )
        return active && correctionOK && estimatedOK && measuredOK
    }

    deinit {
        eventLoopRunning = false
        if let library, let renderContext {
            let freeRender = unsafeBitCast(dlsym(library, "mpv_render_context_free"), to: RenderFree.self)
            freeRender(renderContext)
        }
        if let library, let handle {
            let destroy = unsafeBitCast(dlsym(library, "mpv_terminate_destroy"), to: Destroy.self)
            destroy(handle)
        }
        if let library { dlclose(library) }
    }
}

private struct MPVEvent {
    let eventID: Int32
    let error: Int32
    let replyUserdata: UInt64
    let data: UnsafeMutableRawPointer?
}

private struct MPVEventEndFile {
    let reason: Int32
    let error: Int32
    let playlistEntryID: Int64
    let playlistInsertID: Int64
    let playlistInsertNumEntries: Int32
}

private struct MPVLogMessage {
    let prefix: UnsafePointer<CChar>?
    let level: UnsafePointer<CChar>?
    let text: UnsafePointer<CChar>?
    let logLevel: Int32
}

private struct MPVRenderParam {
    let type: Int32
    let data: UnsafeMutableRawPointer?
}

private struct MPVOpenGLInitParams {
    let getProcAddress: @convention(c) (UnsafeMutableRawPointer?, UnsafePointer<CChar>?) -> UnsafeMutableRawPointer?
    let context: UnsafeMutableRawPointer?
}

private struct MPVOpenGLFBO {
    let fbo: Int32
    let width: Int32
    let height: Int32
    let internalFormat: Int32
}

private let silverGLProcAddress: @convention(c) (UnsafeMutableRawPointer?, UnsafePointer<CChar>?) -> UnsafeMutableRawPointer? = { _, name in
    guard let name else { return nil }
    return dlsym(UnsafeMutableRawPointer(bitPattern: -2), name)
}

private let silverMPVRenderUpdate: @convention(c) (UnsafeMutableRawPointer?) -> Void = { context in
    guard let context else { return }
    let view = Unmanaged<MPVOpenGLView>.fromOpaque(context).takeUnretainedValue()
    DispatchQueue.main.async { view.hasPendingMPVUpdate = true }
}

@MainActor
final class MPVOpenGLView: NSOpenGLView {
    weak var controller: MPVController?
    fileprivate var hasPendingMPVUpdate = true
    private var displayLink: CADisplayLink?
    private var previousDisplayTimestamp: CFTimeInterval?
    private var displayIntervals: [CFTimeInterval] = []
    private var cadenceWindowsSinceLog = 0
    private var hasLoggedCadence = false
    private(set) var measuredRefreshRate: Double?

    init() {
        let attributes: [NSOpenGLPixelFormatAttribute] = [
            UInt32(NSOpenGLPFADoubleBuffer), UInt32(NSOpenGLPFAAccelerated), UInt32(NSOpenGLPFAOpenGLProfile),
            UInt32(NSOpenGLProfileVersion3_2Core), 0
        ]
        super.init(frame: .zero, pixelFormat: NSOpenGLPixelFormat(attributes: attributes))!
        wantsBestResolutionOpenGLSurface = true
        var swapInterval: GLint = 1
        openGLContext?.setValues(&swapInterval, for: .swapInterval)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        displayLink?.invalidate()
        displayLink = nil
        previousDisplayTimestamp = nil
        displayIntervals.removeAll(keepingCapacity: true)
        cadenceWindowsSinceLog = 0
        hasLoggedCadence = false
        measuredRefreshRate = nil
        guard window != nil else { return }
        let link = displayLink(target: self, selector: #selector(displayLinkFired(_:)))
        link.add(to: .main, forMode: .common)
        displayLink = link
        SilverLog.info("Display-bound CADisplayLink attached to mpv render surface")
    }

    @objc private func displayLinkFired(_ link: CADisplayLink) {
        if let previousDisplayTimestamp {
            let interval = link.timestamp - previousDisplayTimestamp
            if interval > 0, interval < 0.2 {
                displayIntervals.append(interval)
                if displayIntervals.count >= 120 {
                    let sorted = displayIntervals.sorted()
                    measuredRefreshRate = 1.0 / sorted[sorted.count / 2]
                    displayIntervals.removeAll(keepingCapacity: true)
                    cadenceWindowsSinceLog += 1
                    if !hasLoggedCadence || cadenceWindowsSinceLog >= 12 {
                        SilverLog.info("Display-link cadence measured refreshRate=\(String(format: "%.9f", measuredRefreshRate!))")
                        hasLoggedCadence = true
                        cadenceWindowsSinceLog = 0
                    }
                }
            }
        }
        previousDisplayTimestamp = link.timestamp
        drawAtDisplaySwap()
    }

    private func drawAtDisplaySwap() {
        guard bounds.width > 0, bounds.height > 0, let controller else { return }
        openGLContext?.makeCurrentContext()
        let scale = window?.backingScaleFactor ?? 1
        controller.renderForDisplaySwap(width: Int32(bounds.width * scale), height: Int32(bounds.height * scale))
        openGLContext?.flushBuffer()
        controller.reportDisplaySwap()
        hasPendingMPVUpdate = false
    }

    override func draw(_ dirtyRect: NSRect) {
        // The display-bound CADisplayLink owns all presentation and swap reports.
    }

    deinit { displayLink?.invalidate() }
}

enum MPVError: LocalizedError {
    case unavailable(String), initialization, renderContext, command, option(String), displaySynchronization, videoPrebuffer, videoPrebufferSuperseded
    var errorDescription: String? {
        switch self {
        case let .unavailable(detail): "The bundled media runtime is unavailable: \(detail)"
        case .initialization: "The MKV/AV1 playback engine could not initialize."
        case .renderContext: "The playback engine could not create its OpenGL render context."
        case .command: "The playback engine rejected a command."
        case let .option(name): "The playback engine rejected option \(name)."
        case .displaySynchronization: "Playback stopped because mpv could not synchronize to the verified display clock."
        case .videoPrebuffer: "Playback stopped because mpv could not prebuffer decoded video safely."
        case .videoPrebufferSuperseded: "The playback operation was superseded by a newer request."
        }
    }
}
