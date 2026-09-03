import AppKit
import Combine
import Foundation

@MainActor
final class AppModel: ObservableObject {
    @Published var hasPlayback = false
    @Published var isHDR = false
    @Published private(set) var catalogReady = false
    let mpv = MPVController()

    private(set) var webServer: WebController?
    private var client: JellyfinClient?
    private var youtubeClient: ZorgYouTubeClient?
    private let display = DisplayModeController()
    private var playingItem: MediaItem?
    private var playingSource: MediaSource?
    private var playingSubtitleLabel = "Off"
    private var activeSubtitleFile: URL?
    private var activeOutputLabel: String?
    private var isPreparingPlayback = false
    private var playbackGeneration = PlaybackOperationGeneration()
    private var prebufferingGeneration: UInt64?
    private var userPaused = false
    private var isPrebuffering: Bool { prebufferingGeneration != nil }
    private var playbackDiagnosticsTask: Task<Void, Never>?
    private var configurationError: String?
    private var isConfigured = false
    private var outputModes: [ConfiguredOutputMode] = []
    private var catalogUserID: String?
    private var catalogRevision = 0

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
        catalogReady = false
        client = nil
        do {
            let configuration = try HomeCinemaConfiguration.load()
            let anonymous = try JellyfinClient(server: configuration.jellyfinURL)
            let session = try await anonymous.authenticate(
                username: configuration.username,
                password: configuration.password
            )
            let authenticated = try JellyfinClient(server: configuration.jellyfinURL, token: session.accessToken)
            client = authenticated
            catalogUserID = session.user.id
            outputModes = configuration.outputModes
            if let url = configuration.youtubeURL, let username = configuration.youtubeUsername,
               let password = configuration.youtubePassword {
                youtubeClient = try ZorgYouTubeClient(server: url, username: username, password: password)
            }
            isConfigured = true
            catalogReady = true
            catalogRevision += 1
            SilverLog.info("Jellyfin connected; catalogue requests will be proxied configuredModes=\(outputModes.count)")
        } catch {
            configurationError = error.localizedDescription
            SilverLog.error("Cannot access Jellyfin: \(error.localizedDescription); terminating")
            NSApp.terminate(nil)
        }
    }

    func webCatalogStatus() -> WebCatalogStatus {
        WebCatalogStatus(
            configured: isConfigured,
            refreshing: false,
            progress: isConfigured ? "Jellyfin connected" : "Connecting to Jellyfin…",
            loadedItems: 0,
            totalItems: nil,
            revision: catalogRevision,
            error: configurationError
        )
    }

    func webLibraryPage(query: String, offset: Int, limit: Int) async throws -> WebLibraryPageResponse {
        guard catalogReady, let client, let catalogUserID else { throw CinemaError.catalogUnavailable }
        let normalizedQuery = query.trimmingCharacters(in: .whitespacesAndNewlines)
        let safeOffset = max(0, offset)
        let safeLimit = min(max(1, limit), 200)
        let page = try await client.catalogPage(
            userID: catalogUserID,
            searchTerm: normalizedQuery,
            startIndex: safeOffset,
            limit: safeLimit
        )
        return WebLibraryPageResponse(
            revision: catalogRevision,
            offset: safeOffset,
            limit: safeLimit,
            total: page.totalRecordCount ?? (safeOffset + page.items.count),
            hasMore: safeOffset + page.items.count < (page.totalRecordCount ?? (safeOffset + page.items.count)),
            items: page.items.map(WebMediaItem.init)
        )
    }

    func webItem(itemID: String) async throws -> WebItemDetail {
        guard let client, let catalogUserID else { throw CinemaError.catalogUnavailable }
        return WebItemDetail(try await client.item(userID: catalogUserID, itemID: itemID))
    }

    func webYouTubeVideos() async throws -> [ZorgYouTubeVideo] {
        guard let youtubeClient else { throw CinemaError.youtubeUnavailable }
        return try await youtubeClient.videos()
    }

    func playYouTube(videoID: String) async throws {
        guard !isPreparingPlayback else { throw CinemaError.busy }
        isPreparingPlayback = true
        defer { isPreparingPlayback = false }
        guard let youtubeClient,
              let video = try await youtubeClient.videos().first(where: { $0.videoId == videoID }),
              let url = youtubeClient.playbackURL(video),
              video.width > 0, video.height > 0, video.frameRate > 0 else {
            throw CinemaError.youtubeUnavailable
        }
        let stream = MediaStream(
            codec: video.videoCodec, type: "Video", index: 0,
            width: video.width, height: video.height, averageFrameRate: video.frameRate,
            videoRange: video.dynamicRange, language: nil, displayTitle: nil, title: nil,
            isDefault: true, isForced: false, isExternal: false
        )
        let audio = MediaStream(
            codec: video.audioCodec, type: "Audio", index: 1,
            width: nil, height: nil, averageFrameRate: nil, videoRange: nil,
            language: nil, displayTitle: nil, title: nil,
            isDefault: true, isForced: false, isExternal: false
        )
        let source = MediaSource(
            id: video.videoId, name: video.title, path: nil, container: "mkv",
            size: video.sizeBytes, bitrate: nil, runTimeTicks: nil, mediaStreams: [stream, audio]
        )
        let item = MediaItem(
            id: video.videoId, name: video.title, type: "YouTube", productionYear: nil,
            seriesName: nil, indexNumber: nil, parentIndexNumber: nil, overview: nil,
            mediaSources: [source]
        )
        SilverLog.info("YouTube playback requested videoID=\(video.videoId) title=\(video.title)")
        try await playPrepared(item: item, source: source, video: stream, url: url)
    }

    func play(itemID: String, subtitleIndex: Int?) async throws {
        guard !isPreparingPlayback else {
            SilverLog.warning("Ignored overlapping playback request itemID=\(itemID)")
            throw CinemaError.busy
        }
        isPreparingPlayback = true
        defer { isPreparingPlayback = false }
        guard let client, let catalogUserID else { throw CinemaError.catalogUnavailable }
        let item = try await client.item(userID: catalogUserID, itemID: itemID)
        guard let source = item.strictSource, let video = source.video,
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
        let subtitleURL: URL? = subtitle.flatMap {
            guard $0.isExternal == true else { return nil }
            return client.subtitleURL(itemID: item.id, sourceID: source.id, index: $0.index)
        }
        let embeddedSubtitleOrdinal = subtitle.flatMap { selected -> Int? in
            guard selected.isExternal != true else { return nil }
            let embedded = source.mediaStreams.filter {
                $0.type == "Subtitle" && $0.isExternal != true
            }
            guard let position = embedded.firstIndex(where: { $0.index == selected.index }) else { return nil }
            return position + 1
        }
        if let subtitle, subtitle.isExternal == true, subtitleURL == nil { throw CinemaError.invalidSubtitle }
        if let subtitle, subtitle.isExternal != true, embeddedSubtitleOrdinal == nil { throw CinemaError.invalidSubtitle }
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
        try await playPrepared(
            item: item, source: source, video: video, url: url,
            subtitle: subtitle, embeddedSubtitleOrdinal: embeddedSubtitleOrdinal,
            preparedSubtitleURL: preparedSubtitleURL
        )
    }

    private func playPrepared(
        item: MediaItem,
        source: MediaSource,
        video: MediaStream,
        url: URL,
        subtitle: MediaStream? = nil,
        embeddedSubtitleOrdinal: Int? = nil,
        preparedSubtitleURL: URL? = nil
    ) async throws {
        stop()
        let generation = playbackGeneration.advance()
        userPaused = false
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
        guard playbackGeneration.isCurrent(generation), hasPlayback else {
            throw MPVError.videoPrebufferSuperseded
        }
        if let error = mpv.attachmentError {
            stop()
            cinemaDelegate.endDisplayModeChange()
            throw error
        }
        guard await cinemaDelegate.verifyDisplayGrabAfterModeChange() else {
            stop()
            throw DisplayModeError.displayGrabLost
        }
        guard playbackGeneration.isCurrent(generation), hasPlayback else {
            throw MPVError.videoPrebufferSuperseded
        }
        guard let outputRefreshRate = currentDisplayOutput()?.refreshRate else {
            stop()
            throw MPVError.displaySynchronization
        }
        try mpv.configureDisplaySync(refreshRate: outputRefreshRate)
        // Hold audio until mpv has configured video output, decoded the first
        // frame, and accumulated input headroom after the HDMI mode change.
        try mpv.setPaused(true)
        try mpv.load(url)
        if let subtitle, let embeddedSubtitleOrdinal {
            do {
                try mpv.selectEmbeddedSubtitle(embeddedSubtitleOrdinal)
            } catch {
                SilverLog.error("Embedded subtitle selection failed item=\(item.name) streamIndex=\(subtitle.index) ordinal=\(embeddedSubtitleOrdinal)")
                stop()
                throw CinemaError.invalidSubtitle
            }
            playingSubtitleLabel = WebSubtitleTrack.label(subtitle)
            SilverLog.info("Embedded subtitle selected item=\(item.name) streamIndex=\(subtitle.index) ordinal=\(embeddedSubtitleOrdinal)")
        } else if let subtitle, let preparedSubtitleURL {
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
        SilverLog.info("Playback load issued item=\(item.name); holding audio for decoded-video prebuffer")
        do {
            try await waitForDecodedVideo(reason: "startup", expectedPosition: nil, generation: generation)
            if !userPaused { try mpv.setPaused(false) }
            SilverLog.info("Decoded-video prebuffer released item=\(item.name) reason=startup resume=\(!userPaused)")
        } catch {
            if playbackGeneration.isCurrent(generation) {
                SilverLog.error("Playback prebuffer failed item=\(item.name) error=\(error.localizedDescription)")
                stop()
            } else {
                SilverLog.info("Playback prebuffer superseded item=\(item.name)")
            }
            throw error
        }
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
                    "demuxerMaxBytes=\(self.mpv.string("demuxer-max-bytes") ?? "nil") " +
                    "demuxerMaxBackBytes=\(self.mpv.string("demuxer-max-back-bytes") ?? "nil") " +
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
        _ = playbackGeneration.advance()
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
        prebufferingGeneration = nil
        userPaused = false
    }

    func seek(to seconds: Double) async throws {
        guard hasPlayback else { throw CinemaError.nothingPlaying }
        guard !isPreparingPlayback else { throw CinemaError.busy }
        guard seconds.isFinite else { return }
        let duration = mpv.number("duration") ?? 0
        let target = max(0, duration.isFinite && duration > 0 ? min(seconds, duration) : seconds)
        let generation = playbackGeneration.advance()
        do {
            try mpv.setPaused(true)
            SilverLog.info("Holding audio for decoded-video prebuffer reason=seek target=\(String(format: "%.3f", target)) generation=\(generation)")
            try mpv.seek(to: target)
            try await waitForDecodedVideo(reason: "seek", expectedPosition: target, generation: generation)
            if !userPaused { try mpv.setPaused(false) }
            SilverLog.info("Decoded-video prebuffer released item=\(playingItem?.name ?? "unknown") reason=seek target=\(String(format: "%.3f", target)) resume=\(!userPaused) generation=\(generation)")
        } catch {
            if playbackGeneration.isCurrent(generation) {
                SilverLog.error("Seek prebuffer failed item=\(playingItem?.name ?? "unknown") target=\(String(format: "%.3f", target)) error=\(error.localizedDescription)")
                stop()
            } else {
                SilverLog.info("Seek prebuffer superseded target=\(String(format: "%.3f", target)) generation=\(generation)")
            }
            throw error
        }
    }

    func pause() throws {
        guard hasPlayback else { throw CinemaError.nothingPlaying }
        SilverLog.info("Pausing playback item=\(playingItem?.name ?? "unknown")")
        try mpv.setPaused(true)
        userPaused = true
    }

    func resume() throws {
        guard hasPlayback else { throw CinemaError.nothingPlaying }
        guard !isPrebuffering else { throw CinemaError.busy }
        SilverLog.info("Resuming playback item=\(playingItem?.name ?? "unknown")")
        try mpv.setPaused(false)
        userPaused = false
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
        let state = isPrebuffering ? "prebuffering" : (mpv.string("pause") == "yes" ? "paused" : "playing")
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

    private func waitForDecodedVideo(reason: String, expectedPosition: Double?, generation: UInt64) async throws {
        prebufferingGeneration = generation
        defer {
            if prebufferingGeneration == generation { prebufferingGeneration = nil }
        }
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: .seconds(15))
        var lastSample = mpv.prebufferSample()
        while clock.now < deadline {
            guard playbackGeneration.isCurrent(generation) else {
                throw MPVError.videoPrebufferSuperseded
            }
            guard hasPlayback else { throw MPVError.videoPrebuffer }
            lastSample = mpv.prebufferSample()
            if lastSample.isReady(expectedPosition: expectedPosition, minimumDemuxedSeconds: 3) {
                // Reject a transient property update: readiness must survive
                // more than two frames of the 24 Hz output clock.
                try await Task.sleep(for: .milliseconds(100))
                guard playbackGeneration.isCurrent(generation) else {
                    throw MPVError.videoPrebufferSuperseded
                }
                let confirmed = mpv.prebufferSample()
                if confirmed.isReady(expectedPosition: expectedPosition, minimumDemuxedSeconds: 3) {
                    SilverLog.info(
                        "Decoded-video prebuffer ready reason=\(reason) " +
                        "position=\(confirmed.position.map { String(format: "%.3f", $0) } ?? "nil") " +
                        "decodedFPS=\(confirmed.decodedFrameRate.map { String(format: "%.6f", $0) } ?? "nil") " +
                        "demuxedSeconds=\(confirmed.demuxedSeconds.map { String(format: "%.3f", $0) } ?? "nil")"
                    )
                    return
                }
            }
            try await Task.sleep(for: .milliseconds(50))
        }
        let position = lastSample.position.map { String(format: "%.3f", $0) } ?? "nil"
        let decodedFPS = lastSample.decodedFrameRate.map { String(format: "%.6f", $0) } ?? "nil"
        let demuxedSeconds = lastSample.demuxedSeconds.map { String(format: "%.3f", $0) } ?? "nil"
        SilverLog.error("Decoded-video prebuffer timed out reason=\(reason) voConfigured=\(lastSample.videoOutputConfigured) videoFormat=\(lastSample.videoFormatAvailable) position=\(position) decodedFPS=\(decodedFPS) demuxedSeconds=\(demuxedSeconds)")
        throw MPVError.videoPrebuffer
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
    case catalogUnavailable
    case youtubeUnavailable
    var errorDescription: String? {
        switch self {
        case .incompatible: "This item is not AV1 + FLAC + SRT in a supported direct-play container."
        case .busy: "Silver is already preparing another playback request."
        case .nothingPlaying: "Nothing is currently playing."
        case .invalidSubtitle: "The selected SRT subtitle track is unavailable."
        case .catalogUnavailable: "The Jellyfin catalogue is not ready yet."
        case .youtubeUnavailable: "The Zorg YouTube catalogue or selected video is unavailable."
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

struct WebLibraryPageResponse: Encodable, Sendable {
    let revision: Int
    let offset: Int
    let limit: Int
    let total: Int
    let hasMore: Bool
    let items: [WebMediaItem]
}

struct WebCatalogStatus: Encodable, Sendable {
    let configured: Bool
    let refreshing: Bool
    let progress: String
    let loadedItems: Int
    let totalItems: Int?
    let revision: Int
    let error: String?
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
