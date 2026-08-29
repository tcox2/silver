import AppKit
import Darwin

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
    private typealias RenderSetUpdate = @convention(c) (OpaquePointer?, (@convention(c) (UnsafeMutableRawPointer?) -> Void)?, UnsafeMutableRawPointer?) -> Void
    private typealias RenderFree = @convention(c) (OpaquePointer?) -> Void

    private var library: UnsafeMutableRawPointer?
    private var handle: OpaquePointer?
    private var pendingURL: URL?
    private var attached = false
    private var eventLoopRunning = false
    private var renderContext: OpaquePointer?
    private weak var renderView: MPVOpenGLView?
    private(set) var attachmentError: Error?

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
        try option("vid", "auto")
        try option("aid", "auto")
        try option("sid", "auto")
        try option("keep-open", "yes")
        try option("terminal", "no")
        let initialize: Initialize = try symbol("mpv_initialize")
        guard initialize(handle) >= 0 else { throw MPVError.initialization }
        try createRenderContext(for: view)
        startEventLogging()
        attached = true
        attachmentError = nil
        SilverLog.info("Media runtime initialized with embedded OpenGL render context")
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
        try command(["loadfile", url.absoluteString, "replace"])
    }

    func stop() { try? command(["stop"]) }
    func seek(to seconds: Double) { try? command(["seek", String(seconds), "absolute+exact"]) }
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
                // MPV_EVENT_LOG_MESSAGE = 2, MPV_EVENT_SHUTDOWN = 1.
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
        renderView = view
        view.controller = self
        let setUpdate: RenderSetUpdate = try symbol("mpv_render_context_set_update_callback")
        setUpdate(context, silverMPVRenderUpdate, Unmanaged.passUnretained(view).toOpaque())
    }

    func render(width: Int32, height: Int32) {
        guard let context = renderContext, let library else { return }
        var fbo = MPVOpenGLFBO(fbo: 0, width: width, height: height, internalFormat: 0)
        var flip: Int32 = 1
        var params: [MPVRenderParam] = withUnsafeMutablePointer(to: &fbo) { fboPointer in
            withUnsafeMutablePointer(to: &flip) { flipPointer in
                [
                    MPVRenderParam(type: 3, data: UnsafeMutableRawPointer(fboPointer)),
                    MPVRenderParam(type: 4, data: UnsafeMutableRawPointer(flipPointer)),
                    MPVRenderParam(type: 0, data: nil)
                ]
            }
        }
        let render = unsafeBitCast(dlsym(library, "mpv_render_context_render"), to: RenderFrame.self)
        params.withUnsafeMutableBufferPointer { render(context, UnsafeMutableRawPointer($0.baseAddress)) }
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
    DispatchQueue.main.async { view.needsDisplay = true }
}

@MainActor
final class MPVOpenGLView: NSOpenGLView {
    weak var controller: MPVController?

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

    override func draw(_ dirtyRect: NSRect) {
        guard bounds.width > 0, bounds.height > 0 else { return }
        openGLContext?.makeCurrentContext()
        let scale = window?.backingScaleFactor ?? 1
        controller?.render(width: Int32(bounds.width * scale), height: Int32(bounds.height * scale))
        openGLContext?.flushBuffer()
    }
}

enum MPVError: LocalizedError {
    case unavailable(String), initialization, renderContext, command, option(String)
    var errorDescription: String? {
        switch self {
        case let .unavailable(detail): "The bundled media runtime is unavailable: \(detail)"
        case .initialization: "The MKV/AV1 playback engine could not initialize."
        case .renderContext: "The playback engine could not create its OpenGL render context."
        case .command: "The playback engine rejected a command."
        case let .option(name): "The playback engine rejected option \(name)."
        }
    }
}
