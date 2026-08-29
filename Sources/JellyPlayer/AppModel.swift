import AppKit
import Combine
import Foundation

@MainActor
final class AppModel: ObservableObject {
    @Published var hasPlayback = false
    @Published var isHDR = false
    let mpv = MPVController()

    private(set) var webServer: WebController?
    private var client: JellyfinClient?
    private var items: [MediaItem] = []
    private let display = DisplayModeController()
    private var playingItem: MediaItem?
    private var playingSource: MediaSource?
    private var activeOutputLabel: String?
    private var configurationError: String?
    private var isConfigured = false
    private var outputModes: [ConfiguredOutputMode] = []

    func start() {
        guard webServer == nil else { return }
        let server = WebController(model: self)
        webServer = server
        server.start(port: 8099)
        Task { await loadConfiguration() }
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
            isConfigured = true
        } catch {
            configurationError = error.localizedDescription
            fputs("Silver cannot access Jellyfin: \(error.localizedDescription)\n", stderr)
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
        guard let client, let item = items.first(where: { $0.id == itemID }),
              let source = item.strictSource, let video = source.video,
              let url = client.playbackURL(itemID: item.id, source: source) else {
            throw CinemaError.incompatible
        }
        stop()
        playingItem = item
        playingSource = source
        isHDR = video.isHDR
        do {
            activeOutputLabel = try display.apply(
                width: video.width,
                height: video.height,
                frameRate: video.averageFrameRate,
                hdr: video.isHDR,
                configuredModes: outputModes
            )
        } catch {
            stop()
            throw error
        }
        hasPlayback = true
        try mpv.load(url)
    }

    func stop() {
        mpv.stop()
        hasPlayback = false
        isHDR = false
        display.restore()
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
        guard hasPlayback, let item = playingItem, let source = playingSource else {
            return WebPlaybackStatus(nowPlaying: nil)
        }
        let video = source.video
        let current = mpv.number("time-pos") ?? 0
        let rawDuration = mpv.number("duration") ?? 0
        let duration = rawDuration.isFinite && rawDuration > 0 ? rawDuration : nil
        let audio = source.mediaStreams.filter { $0.type == "Audio" }.map(\.codec).joined(separator: ", ").uppercased()
        let state = mpv.string("pause") == "yes" ? "paused" : "playing"
        return WebPlaybackStatus(nowPlaying: WebNowPlaying(
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
    var errorDescription: String? { "This item is not AV1 + FLAC + SRT in an Apple-compatible container." }
}

struct WebPlaybackStatus: Encodable, Sendable { let nowPlaying: WebNowPlaying? }

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
