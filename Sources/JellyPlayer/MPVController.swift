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

    private var library: UnsafeMutableRawPointer?
    private var handle: OpaquePointer?
    private var pendingURL: URL?
    private var attached = false

    func attach(to view: NSView) throws {
        guard !attached else { return }
        let path = "/Applications/Jellyfin Desktop.app/Contents/Frameworks/libmpv.2.dylib"
        guard let library = dlopen(path, RTLD_NOW | RTLD_LOCAL) else { throw MPVError.unavailable }
        self.library = library
        let create: Create = try symbol("mpv_create")
        guard let handle = create() else { throw MPVError.unavailable }
        self.handle = handle
        let pointer = UInt(bitPattern: Unmanaged.passUnretained(view).toOpaque())
        try option("wid", String(pointer))
        try option("vo", "gpu-next")
        try option("hwdec", "no")
        try option("keep-open", "yes")
        try option("terminal", "no")
        let initialize: Initialize = try symbol("mpv_initialize")
        guard initialize(handle) >= 0 else { throw MPVError.initialization }
        attached = true
        if let pendingURL {
            do { try load(pendingURL); self.pendingURL = nil }
            catch {
                fputs("Playback engine load failed: \(error.localizedDescription)\n", stderr)
                throw error
            }
        }
    }

    func load(_ url: URL) throws {
        guard attached else { pendingURL = url; return }
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
        guard let library, let pointer = dlsym(library, name) else { throw MPVError.unavailable }
        return unsafeBitCast(pointer, to: T.self)
    }

    deinit {
        if let library, let handle {
            let destroy = unsafeBitCast(dlsym(library, "mpv_terminate_destroy"), to: Destroy.self)
            destroy(handle)
        }
        if let library { dlclose(library) }
    }
}

enum MPVError: LocalizedError {
    case unavailable, initialization, command, option(String)
    var errorDescription: String? {
        switch self {
        case .unavailable: "Jellyfin Desktop's media runtime is unavailable."
        case .initialization: "The MKV/AV1 playback engine could not initialize."
        case .command: "The playback engine rejected a command."
        case let .option(name): "The playback engine rejected option \(name)."
        }
    }
}
