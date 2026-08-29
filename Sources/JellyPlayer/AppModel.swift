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
    private var playingSubtitleLabel = "Off"
    private var activeSubtitleFile: URL?
    private var activeOutputLabel: String?
    private var isPreparingPlayback = false
    private var playbackDiagnosticsTask: Task<Void, Never>?
    private var configurationError: String?
    private var isConfigured = false
    private var outputModes: [ConfiguredOutputMode] = []

    func start() {
        guard webServer == nil else { return }
        CinemaRestoration.restore = { [weak self] in self?.stop() }
        mpv.playbackEnded = { [weak self] in
            guard let self, self.hasPlayback else { return }
            SilverLog.info("Playback reached end of file item=\(self.playingItem?.name ?? "unknown")")
            self.stop()
        }
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
            items = try await authenticated.catalogItems(userID: session.user.id)
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

    func webItem(itemID: String) throws -> WebItemDetail {
        guard let item = items.first(where: { $0.id == itemID }) else {
            throw CinemaError.incompatible
        }
        return WebItemDetail(item)
    }

    func play(itemID: String, subtitleIndex: Int?) async throws {
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
        let subtitle = subtitleIndex.flatMap { requestedIndex in
            source.mediaStreams.first {
                $0.type == "Subtitle" && $0.index == requestedIndex &&
                ["srt", "subrip"].contains($0.codec.lowercased())
            }
        }
        if subtitleIndex != nil, subtitle == nil { throw CinemaError.invalidSubtitle }
        let subtitleURL = subtitle.flatMap {
            client.subtitleURL(itemID: item.id, sourceID: source.id, index: $0.index)
        }
        if subtitle != nil, subtitleURL == nil { throw CinemaError.invalidSubtitle }
        var preparedSubtitleURL: URL?
        if let subtitle, let subtitleURL {
            do {
                SilverLog.info("Downloading selected subtitle before playback item=\(item.name) streamIndex=\(subtitle.index)")
                let text = try await client.loadText(from: subtitleURL)
                guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                    throw CinemaError.invalidSubtitle
                }
                let directory = FileManager.default.temporaryDirectory
                    .appendingPathComponent("Silver", isDirectory: true)
                    .appendingPathComponent("Subtitles", isDirectory: true)
                try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
                let file = directory.appendingPathComponent(UUID().uuidString).appendingPathExtension("srt")
                try text.write(to: file, atomically: true, encoding: .utf8)
                preparedSubtitleURL = file
                SilverLog.info("Selected subtitle ready item=\(item.name) streamIndex=\(subtitle.index) bytes=\(text.utf8.count)")
            } catch {
                SilverLog.error("Selected subtitle download failed item=\(item.name) streamIndex=\(subtitle.index) error=\(error.localizedDescription)")
                throw CinemaError.invalidSubtitle
            }
        }
        SilverLog.info("Playback requested item=\(item.name) source=\(source.id) subtitle=\(subtitle?.index.description ?? "off")")
        stop()
        activeSubtitleFile = preparedSubtitleURL
        playingItem = item
        playingSource = source
        playingSubtitleLabel = "Off"
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
        guard let outputRefreshRate = currentDisplayOutput()?.refreshRate else {
            stop()
            throw MPVError.displaySynchronization
        }
        try mpv.configureDisplaySync(refreshRate: outputRefreshRate)
        try mpv.load(url)
        if let subtitle, let preparedSubtitleURL {
            do {
                try mpv.addSubtitle(preparedSubtitleURL)
            } catch {
                SilverLog.error("Selected subtitle attachment failed item=\(item.name) streamIndex=\(subtitle.index)")
                stop()
                throw CinemaError.invalidSubtitle
            }
            playingSubtitleLabel = WebSubtitleTrack.label(subtitle)
            SilverLog.info("Selected subtitle attached item=\(item.name) streamIndex=\(subtitle.index)")
        }
        SilverLog.info("Playback load issued item=\(item.name)")
        playbackDiagnosticsTask?.cancel()
        playbackDiagnosticsTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(3))
            var diagnosticPass = 0
            var synchronizationVerified = false
            while !Task.isCancelled, let self, self.hasPlayback {
                let videoFormat = self.mpv.string("video-format")
                let videoCodec = self.mpv.string("video-codec")
                let voConfigured = self.mpv.string("vo-configured")
                SilverLog.info(
                    "Playback diagnostics time=\(self.mpv.string("time-pos") ?? "nil") " +
                    "videoFormat=\(videoFormat ?? "nil") videoCodec=\(videoCodec ?? "nil") " +
                    "voConfigured=\(voConfigured ?? "nil") " +
                    "decoderDrops=\(self.mpv.string("decoder-frame-drop-count") ?? "nil") " +
                    "rendererDrops=\(self.mpv.string("frame-drop-count") ?? "nil") " +
                    "mistimedFrames=\(self.mpv.string("mistimed-frame-count") ?? "nil") " +
                    "delayedFrames=\(self.mpv.string("vo-delayed-frame-count") ?? "nil") " +
                    "avSync=\(self.mpv.string("avsync") ?? "nil") " +
                    "totalAvSyncChange=\(self.mpv.string("total-avsync-change") ?? "nil") " +
                    "decodedFPS=\(self.mpv.string("estimated-vf-fps") ?? "nil") " +
                    "decoderQueue=\(self.mpv.string("vd-queue-enable") ?? "nil")/\(self.mpv.string("vd-queue-max-samples") ?? "nil")frames " +
                    "decoderQueueBytes=\(self.mpv.string("vd-queue-max-bytes") ?? "nil") " +
                    "decoderQueueSeconds=\(self.mpv.string("vd-queue-max-secs") ?? "nil") " +
                    "pausedForCache=\(self.mpv.string("paused-for-cache") ?? "nil") " +
                    "cacheDuration=\(self.mpv.string("demuxer-cache-duration") ?? "nil") " +
                    "cacheSpeed=\(self.mpv.string("cache-speed") ?? "nil") " +
                    "cacheIdle=\(self.mpv.string("demuxer-cache-idle") ?? "nil") " +
                    "videoSync=\(self.mpv.string("video-sync") ?? "nil") " +
                    "displaySyncActive=\(self.mpv.string("display-sync-active") ?? "nil") " +
                    "estimatedDisplayFPS=\(self.mpv.string("estimated-display-fps") ?? "nil") " +
                    "videoSpeedCorrection=\(self.mpv.string("video-speed-correction") ?? "nil") " +
                    "audioSpeedCorrection=\(self.mpv.string("audio-speed-correction") ?? "nil")"
                )
                if voConfigured != "yes" || videoFormat == nil {
                    SilverLog.error("Playback stopped because decoded video output was not established")
                    self.stop()
                    return
                }
                if !synchronizationVerified, diagnosticPass >= 1 {
                    guard let sourceFrameRate = video.averageFrameRate,
                          self.mpv.verifyDisplaySynchronization(
                            sourceFrameRate: sourceFrameRate,
                            outputRefreshRate: outputRefreshRate
                          ) else {
                        SilverLog.error("Playback stopped because display-clock synchronization verification failed")
                        self.stop()
                        return
                    }
                    synchronizationVerified = true
                }
                diagnosticPass += 1
                try? await Task.sleep(for: .seconds(10))
            }
        }
    }

    func stop() {
        if let playingItem { SilverLog.info("Stopping playback item=\(playingItem.name)") }
        playbackDiagnosticsTask?.cancel()
        playbackDiagnosticsTask = nil
        mpv.stop()
        if let activeSubtitleFile {
            try? FileManager.default.removeItem(at: activeSubtitleFile)
            self.activeSubtitleFile = nil
        }
        display.restore()
        isHDR = false
        CinemaAppDelegate.shared?.prepareDynamicRange(hdr: false)
        hasPlayback = false
        playingItem = nil
        playingSource = nil
        playingSubtitleLabel = "Off"
        activeOutputLabel = nil
    }

    func seek(to seconds: Double) {
        guard seconds.isFinite else { return }
        let duration = mpv.number("duration") ?? 0
        let target = max(0, duration.isFinite && duration > 0 ? min(seconds, duration) : seconds)
        mpv.seek(to: target)
    }

    func pause() throws {
        guard hasPlayback else { throw CinemaError.nothingPlaying }
        SilverLog.info("Pausing playback item=\(playingItem?.name ?? "unknown")")
        try mpv.setPaused(true)
    }

    func resume() throws {
        guard hasPlayback else { throw CinemaError.nothingPlaying }
        SilverLog.info("Resuming playback item=\(playingItem?.name ?? "unknown")")
        try mpv.setPaused(false)
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
            subtitles: playingSubtitleLabel,
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

struct WebItemDetail: Encodable, Sendable {
    let id: String
    let name: String
    let detail: String
    let compatible: Bool
    let incompatibilityReason: String?
    let overview: String?
    let file: WebFileInfo?
    let subtitles: [WebSubtitleTrack]

    init(_ item: MediaItem) {
        id = item.id
        name = item.name
        detail = item.subtitle
        compatible = item.strictSource != nil
        incompatibilityReason = item.incompatibilityReason
        overview = item.overview
        let source = item.strictSource ?? item.mediaSources?.first
        file = source.map(WebFileInfo.init)
        subtitles = source?.mediaStreams.filter {
            $0.type == "Subtitle" && ["srt", "subrip"].contains($0.codec.lowercased())
        }.map(WebSubtitleTrack.init) ?? []
    }
}

enum CinemaError: LocalizedError {
    case incompatible
    case busy
    case nothingPlaying
    case invalidSubtitle
    var errorDescription: String? {
        switch self {
        case .incompatible: "This item is not AV1 + FLAC + SRT in a supported direct-play container."
        case .busy: "Silver is already preparing another playback request."
        case .nothingPlaying: "Nothing is currently playing."
        case .invalidSubtitle: "The selected SRT subtitle track is unavailable."
        }
    }
}

struct WebFileInfo: Encodable, Sendable {
    let name: String
    let container: String
    let size: Int64?
    let bitrate: Int?
    let duration: Double?
    let videoCodec: String
    let width: Int?
    let height: Int?
    let frameRate: Double?
    let dynamicRange: String
    let audio: [String]

    init(_ source: MediaSource) {
        name = source.path.map { URL(fileURLWithPath: $0).lastPathComponent } ?? source.name ?? "Unknown"
        container = source.container?.uppercased() ?? "Unknown"
        size = source.size
        bitrate = source.bitrate
        duration = source.runTimeTicks.map { Double($0) / 10_000_000 }
        videoCodec = source.video?.codec.uppercased() ?? "Unknown"
        width = source.video?.width
        height = source.video?.height
        frameRate = source.video?.averageFrameRate
        dynamicRange = source.video?.isHDR == true ? "HDR" : "SDR"
        audio = source.mediaStreams.filter { $0.type == "Audio" }.map {
            [$0.codec.uppercased(), $0.language, $0.displayTitle ?? $0.title].compactMap { $0 }.joined(separator: " · ")
        }
    }
}

struct WebSubtitleTrack: Encodable, Sendable {
    let index: Int
    let label: String
    let language: String?
    let isDefault: Bool
    let isForced: Bool
    let isExternal: Bool

    init(_ stream: MediaStream) {
        index = stream.index
        label = Self.label(stream)
        language = stream.language
        isDefault = stream.isDefault == true
        isForced = stream.isForced == true
        isExternal = stream.isExternal == true
    }

    static func label(_ stream: MediaStream) -> String {
        var parts = [stream.displayTitle ?? stream.title ?? stream.language ?? "SRT"]
        if stream.isForced == true { parts.append("Forced") }
        else if stream.isDefault == true { parts.append("Default") }
        return parts.joined(separator: " · ")
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
