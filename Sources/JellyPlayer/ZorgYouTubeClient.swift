import Foundation

struct ZorgYouTubeVideo: Codable, Sendable {
    let title: String; let videoId: String; let downloadedAt: String
    let channel: String?
    let sizeBytes: Int64; let downloadUrl: String
    let width: Int; let height: Int; let frameRate: Double
    let dynamicRange: String; let videoCodec: String; let audioCodec: String
}

struct ZorgYouTubeClient: Sendable {
    let baseURL: URL; let username: String; let password: String
    init(server: String, username: String, password: String) throws {
        guard let url = URL(string: server), url.scheme == "https", url.host != nil else { throw CinemaError.youtubeUnavailable }
        baseURL = url; self.username = username; self.password = password
    }
    func videos() async throws -> [ZorgYouTubeVideo] {
        var request = URLRequest(url: baseURL.appending(path: "api/youtube/videos"))
        request.setValue("Basic " + Data("\(username):\(password)".utf8).base64EncodedString(), forHTTPHeaderField: "Authorization")
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else { throw CinemaError.youtubeUnavailable }
        return try JSONDecoder().decode([ZorgYouTubeVideo].self, from: data)
    }
    func playbackURL(_ video: ZorgYouTubeVideo) -> URL? {
        guard var components = URLComponents(url: baseURL, resolvingAgainstBaseURL: false) else { return nil }
        components.user = username; components.password = password
        guard let root = components.url else { return nil }
        return URL(string: video.downloadUrl, relativeTo: root)?.absoluteURL
    }
}
