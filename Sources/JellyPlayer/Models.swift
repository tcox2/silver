import Foundation

struct JellyfinSession: Codable, Sendable {
    let accessToken: String
    let user: JellyfinUser

    enum CodingKeys: String, CodingKey {
        case accessToken = "AccessToken"
        case user = "User"
    }
}

struct JellyfinUser: Codable, Sendable {
    let id: String
    let name: String

    enum CodingKeys: String, CodingKey {
        case id = "Id"
        case name = "Name"
    }
}

struct JellyfinItemsResponse: Codable, Sendable {
    let items: [MediaItem]

    enum CodingKeys: String, CodingKey {
        case items = "Items"
    }
}

struct MediaItem: Codable, Identifiable, Hashable, Sendable {
    let id: String
    let name: String
    let type: String?
    let productionYear: Int?
    let seriesName: String?
    let indexNumber: Int?
    let parentIndexNumber: Int?
    let overview: String?
    let mediaSources: [MediaSource]?

    enum CodingKeys: String, CodingKey {
        case id = "Id"
        case name = "Name"
        case type = "Type"
        case productionYear = "ProductionYear"
        case seriesName = "SeriesName"
        case indexNumber = "IndexNumber"
        case parentIndexNumber = "ParentIndexNumber"
        case overview = "Overview"
        case mediaSources = "MediaSources"
    }

    var subtitle: String {
        if type == "Episode", let seriesName {
            let episode = [parentIndexNumber.map { "S\($0)" }, indexNumber.map { "E\($0)" }]
                .compactMap { $0 }.joined()
            return episode.isEmpty ? seriesName : "\(seriesName) · \(episode)"
        }
        return productionYear.map(String.init) ?? type ?? "Video"
    }

    var strictSource: MediaSource? {
        mediaSources?.first { $0.isStrictlyCompatible }
    }

    var incompatibilityReason: String? {
        guard strictSource == nil else { return nil }
        guard let source = mediaSources?.first else { return "No playable media source" }
        var reasons: [String] = []
        let container = source.container?.lowercased() ?? "unknown"
        if !["mp4", "m4v", "mov", "mkv", "matroska"].contains(container) {
            reasons.append("\(container.uppercased()) container")
        }
        let videoCodec = source.video?.codec.lowercased() ?? "missing"
        if videoCodec != "av1" { reasons.append("\(videoCodec.uppercased()) video") }
        let audioCodecs = Set(source.mediaStreams.filter { $0.type == "Audio" }.map { $0.codec.lowercased() })
        if audioCodecs.isEmpty { reasons.append("no audio") }
        else if audioCodecs.contains(where: { $0 != "flac" }) {
            reasons.append("\(audioCodecs.sorted().joined(separator: ", ").uppercased()) audio")
        }
        let subtitleCodecs = Set(source.mediaStreams.filter { $0.type == "Subtitle" }.map { $0.codec.lowercased() })
        if subtitleCodecs.contains(where: { !["srt", "subrip"].contains($0) }) {
            reasons.append("\(subtitleCodecs.sorted().joined(separator: ", ").uppercased()) subtitles")
        }
        return reasons.isEmpty ? "No compatible source" : reasons.joined(separator: " · ")
    }
}

struct MediaSource: Codable, Hashable, Sendable {
    let id: String
    let container: String?
    let mediaStreams: [MediaStream]

    enum CodingKeys: String, CodingKey {
        case id = "Id"
        case container = "Container"
        case mediaStreams = "MediaStreams"
    }

    var video: MediaStream? { mediaStreams.first { $0.type == "Video" } }
    var subtitle: MediaStream? {
        mediaStreams.first {
            $0.type == "Subtitle" && ["srt", "subrip"].contains($0.codec.lowercased())
        }
    }
    var isStrictlyCompatible: Bool {
        guard ["mp4", "m4v", "mov", "mkv", "matroska"].contains(container?.lowercased() ?? ""),
              video?.codec.lowercased() == "av1" else { return false }
        return mediaStreams.filter { $0.type == "Audio" }.allSatisfy { $0.codec.lowercased() == "flac" }
            && mediaStreams.filter { $0.type == "Subtitle" }
                .allSatisfy { ["srt", "subrip"].contains($0.codec.lowercased()) }
    }
}

struct MediaStream: Codable, Hashable, Sendable {
    let codec: String
    let type: String
    let index: Int
    let width: Int?
    let height: Int?
    let averageFrameRate: Double?
    let videoRange: String?

    enum CodingKeys: String, CodingKey {
        case codec = "Codec"
        case type = "Type"
        case index = "Index"
        case width = "Width"
        case height = "Height"
        case averageFrameRate = "AverageFrameRate"
        case videoRange = "VideoRange"
    }

    var isHDR: Bool { !(videoRange ?? "SDR").uppercased().contains("SDR") }
}

struct Credentials: Codable, Sendable {
    var server = ""
    var username = ""
    var password = ""
}

enum JellyfinError: LocalizedError {
    case invalidServer
    case invalidResponse
    case invalidCredentials
    case server(Int, String)

    var errorDescription: String? {
        switch self {
        case .invalidServer:
            "Enter a complete Jellyfin URL, such as https://media.example.com."
        case .invalidResponse:
            "The server returned a response Silver could not understand."
        case .invalidCredentials:
            "Incorrect Jellyfin username or password."
        case let .server(code, message):
            message.isEmpty ? "Jellyfin returned HTTP \(code)." : message
        }
    }
}
