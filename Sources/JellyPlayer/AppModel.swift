import AppKit
import Combine
import Foundation

@MainActor
final class AppModel: ObservableObject {
    @Published var hasPlayback = false
    @Published var isHDR = false
    @Published var configuredOutputModeDescriptions: [String] = []
    let mpv = MPVController()

    private(set) var webServer: WebController?
    private var client: JellyfinClient?
    private var items: [MediaItem] = []
    private let display = DisplayModeController()
    private var playingItem: MediaItem?
    private var playingSource: MediaSource?
    private var activeOutputLabel: String?
    private var isPreparingPlayback = false
    private var configurationError: String?
    private var isConfigured = false
    private var outputModes: [ConfiguredOutputMode] = []

    func start() {
        guard webServer == nil else { return }
        CinemaRestoration.restore = { [weak self] in self?.stop() }
        do {
            try display.ensureIdleSDR()
        } catch {
            SilverLog.error("Cannot establish idle SDR output: \(error.localizedDescription); terminating")
            NSApp.terminate(nil)
            return
        }
        SilverLog.info("Starting web controller port=8099")
        let server = WebController(model: self)
        webServer = server
        server.start(port: 8099)
        Task { await loadConfiguration() }
    }

    func webControllerFailed(_ message: String) {
        SilverLog.error("Cannot own web controller: \(message); terminating")
        NSApp.terminate(nil)
    }

    func loadConfiguration() async {
        configurationError = nil
        isConfigured = false
        client = nil
        items = []
        do {
            let configuration = try HomeCinemaConfiguration.load()
            let anonymous = try JellyfinClient(server: configuration.jellyfinURL)
            let session = try await anonymous.authenticate(
                username: configuration.username,
                password: configuration.password
            )
            let authenticated = try JellyfinClient(server: configuration.jellyfinURL, token: session.accessToken)
            items = try await authenticated.latestItems(userID: session.user.id)
            client = authenticated
            outputModes = configuration.outputModes
            configuredOutputModeDescriptions = configuration.outputModes.map {
                "\($0.label) — \($0.displayWidth)×\($0.displayHeight) · \(String(format: "%.3f", $0.displayRefreshRate)) Hz · \($0.mediaDynamicRange.uppercased())"
            }
            isConfigured = true
            SilverLog.info("Jellyfin connected; libraryItems=\(items.count) configuredModes=\(outputModes.count)")
        } catch {
            configurationError = error.localizedDescription
            SilverLog.error("Cannot access Jellyfin: \(error.localizedDescription); terminating")
            NSApp.terminate(nil)
        }
    }

    func webLibrary() -> WebLibraryResponse {
        WebLibraryResponse(
            configured: isConfigured,
            error: configurationError,
            items: items.map(WebMediaItem.init)
        )
    }

    func play(itemID: String) async throws {
        guard !isPreparingPlayback else {
            SilverLog.warning("Ignored overlapping playback request itemID=\(itemID)")
            throw CinemaError.busy
        }
        isPreparingPlayback = true
        defer { isPreparingPlayback = false }
        guard let client, let item = items.first(where: { $0.id == itemID }),
              let source = item.strictSource, let video = source.video,
              let url = client.playbackURL(itemID: item.id, source: source) else {
            throw CinemaError.incompatible
        }
        SilverLog.info("Playback requested item=\(item.name) source=\(source.id)")
        stop()
        playingItem = item
        playingSource = source
        isHDR = video.isHDR
        guard let cinemaDelegate = CinemaAppDelegate.shared else {
            SilverLog.error("Playback blocked because the cinema application delegate is unavailable")
            throw DisplayModeError.displayGrabLost
        }
        cinemaDelegate.beginDisplayModeChange()
        cinemaDelegate.prepareDynamicRange(hdr: video.isHDR)
        do {
            activeOutputLabel = try display.apply(
                width: video.width,
                height: video.height,
                frameRate: video.averageFrameRate,
                hdr: video.isHDR,
                configuredModes: outputModes
            )
        } catch {
            SilverLog.error("Playback display preparation failed item=\(item.name) error=\(error.localizedDescription)")
            stop()
            cinemaDelegate.endDisplayModeChange()
            throw error
        }
        hasPlayback = true
        await Task.yield()
        if let error = mpv.attachmentError {
            stop()
            cinemaDelegate.endDisplayModeChange()
            throw error
        }
        guard await cinemaDelegate.verifyDisplayGrabAfterModeChange() else {
            stop()
            throw DisplayModeError.displayGrabLost
        }
        try mpv.load(url)
        SilverLog.info("Playback load issued item=\(item.name)")
        Task { [weak self] in
            try? await Task.sleep(for: .seconds(3))
            guard let self, self.hasPlayback else { return }
            SilverLog.info(
                "Playback diagnostics time=\(self.mpv.string("time-pos") ?? "nil") " +
                "videoFormat=\(self.mpv.string("video-format") ?? "nil") " +
                "voConfigured=\(self.mpv.string("vo-configured") ?? "nil") " +
                "pausedForCache=\(self.mpv.string("paused-for-cache") ?? "nil")"
            )
        }
    }

    func stop() {
        if let playingItem { SilverLog.info("Stopping playback item=\(playingItem.name)") }
        mpv.stop()
        display.restore()
        isHDR = false
        CinemaAppDelegate.shared?.prepareDynamicRange(hdr: false)
        hasPlayback = false
        playingItem = nil
        playingSource = nil
        activeOutputLabel = nil
    }

    func seek(to seconds: Double) {
        guard seconds.isFinite else { return }
        let duration = mpv.number("duration") ?? 0
        let target = max(0, duration.isFinite && duration > 0 ? min(seconds, duration) : seconds)
        mpv.seek(to: target)
    }

    func webStatus() -> WebPlaybackStatus {
        let currentOutput = currentDisplayOutput()
        guard hasPlayback, let item = playingItem, let source = playingSource else {
            return WebPlaybackStatus(currentOutput: currentOutput, nowPlaying: nil)
        }
        let video = source.video
        let current = mpv.number("time-pos") ?? 0
        let rawDuration = mpv.number("duration") ?? 0
        let duration = rawDuration.isFinite && rawDuration > 0 ? rawDuration : nil
        let audio = source.mediaStreams.filter { $0.type == "Audio" }.map(\.codec).joined(separator: ", ").uppercased()
        let state = mpv.string("pause") == "yes" ? "paused" : "playing"
        return WebPlaybackStatus(currentOutput: currentOutput, nowPlaying: WebNowPlaying(
            id: item.id,
            title: item.name,
            detail: item.subtitle,
            state: state,
            error: nil,
            currentTime: current.isFinite ? max(0, current) : 0,
            duration: duration,
            frameRate: video?.averageFrameRate,
            width: video?.width,
            height: video?.height,
            dynamicRange: video?.isHDR == true ? "HDR" : "SDR",
            videoCodec: video?.codec.uppercased() ?? "AV1",
            audioCodec: audio.isEmpty ? "None" : audio,
            subtitles: source.subtitle == nil ? "Off" : "SRT",
            outputMode: activeOutputLabel ?? "Unknown"
        ))
    }

    private func currentDisplayOutput() -> WebDisplayOutput? {
        guard let screen = NSScreen.main,
              let number = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber,
              let mode = CGDisplayCopyDisplayMode(number.uint32Value) else { return nil }
        return WebDisplayOutput(
            name: screen.localizedName,
            width: mode.pixelWidth,
            height: mode.pixelHeight,
            refreshRate: mode.refreshRate,
            // Tahoe reports currentEDR == 1.0 even while the external HDR mode is
            // enabled. `isHDR` is set only after CoreDisplay read-back and EDR
            // capability verification have both succeeded.
            dynamicRange: isHDR ? "HDR" : "SDR",
            hdrPotential: screen.maximumPotentialExtendedDynamicRangeColorComponentValue > 1.0
        )
    }

}

struct WebMediaItem: Encodable, Sendable {
    let id: String
    let name: String
    let detail: String
    let compatible: Bool
    let incompatibilityReason: String?
    init(_ item: MediaItem) {
        id = item.id
        name = item.name
        detail = item.subtitle
        compatible = item.strictSource != nil
        incompatibilityReason = item.incompatibilityReason
    }
}

enum CinemaError: LocalizedError {
    case incompatible
    case busy
    var errorDescription: String? {
        switch self {
        case .incompatible: "This item is not AV1 + FLAC + SRT in a supported direct-play container."
        case .busy: "Silver is already preparing another playback request."
        }
    }
}

struct WebPlaybackStatus: Encodable, Sendable {
    let currentOutput: WebDisplayOutput?
    let nowPlaying: WebNowPlaying?
}

struct WebDisplayOutput: Encodable, Sendable {
    let name: String
    let width: Int
    let height: Int
    let refreshRate: Double
    let dynamicRange: String
    let hdrPotential: Bool
}

struct WebLibraryResponse: Encodable, Sendable {
    let configured: Bool
    let error: String?
    let items: [WebMediaItem]
}

struct WebNowPlaying: Encodable, Sendable {
    let id: String
    let title: String
    let detail: String
    let state: String
    let error: String?
    let currentTime: Double
    let duration: Double?
    let frameRate: Double?
    let width: Int?
    let height: Int?
    let dynamicRange: String
    let videoCodec: String
    let audioCodec: String
    let subtitles: String
    let outputMode: String
}
