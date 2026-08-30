import Foundation

struct JellyfinClient: Sendable {
    static let clientName = "Silver"
    static let version = "0.1.0"

    let baseURL: URL
    let token: String?

    init(server: String, token: String? = nil) throws {
        let value = server.trimmingCharacters(in: .whitespacesAndNewlines)
        guard var components = URLComponents(string: value),
              let scheme = components.scheme?.lowercased(),
              ["http", "https"].contains(scheme),
              components.host != nil else {
            throw JellyfinError.invalidServer
        }
        components.path = components.path.replacingOccurrences(of: "/+$", with: "", options: .regularExpression)
        guard let url = components.url else { throw JellyfinError.invalidServer }
        baseURL = url
        self.token = token
    }

    func authenticate(username: String, password: String) async throws -> JellyfinSession {
        var request = try request(path: "/Users/AuthenticateByName", method: "POST")
        request.httpBody = try JSONEncoder().encode(["Username": username, "Pw": password])
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        return try await send(request, as: JellyfinSession.self)
    }

    func catalogItems(
        userID: String,
        progress: @MainActor @Sendable (Int, Int?) -> Void = { _, _ in }
    ) async throws -> [MediaItem] {
        let pageSize = 500
        var startIndex = 0
        var catalog: [MediaItem] = []
        while true {
            let query = [
                URLQueryItem(name: "UserId", value: userID),
                URLQueryItem(name: "IncludeItemTypes", value: "Movie,Episode"),
                URLQueryItem(name: "Recursive", value: "true"),
                URLQueryItem(name: "SortBy", value: "SortName"),
                URLQueryItem(name: "SortOrder", value: "Ascending"),
                URLQueryItem(name: "StartIndex", value: String(startIndex)),
                URLQueryItem(name: "Limit", value: String(pageSize)),
                URLQueryItem(name: "Fields", value: "Overview,MediaSources")
            ]
            let response = try await send(request(path: "/Items", query: query), as: JellyfinItemsResponse.self)
            catalog.append(contentsOf: response.items)
            startIndex += response.items.count
            await progress(startIndex, response.totalRecordCount)
            if response.items.isEmpty || response.items.count < pageSize ||
                response.totalRecordCount.map({ startIndex >= $0 }) == true { break }
        }
        return catalog
    }

    func playbackURL(itemID: String, source: MediaSource) -> URL? {
        return makeURL(path: "/Videos/\(itemID)/stream", query: [
            URLQueryItem(name: "Static", value: "true"),
            URLQueryItem(name: "MediaSourceId", value: source.id),
            URLQueryItem(name: "api_key", value: token)
        ])
    }

    func subtitleURL(itemID: String, sourceID: String, index: Int) -> URL? {
        makeURL(path: "/Videos/\(itemID)/\(sourceID)/Subtitles/\(index)/Stream.srt", query: [
            URLQueryItem(name: "api_key", value: token)
        ])
    }

    func loadText(from url: URL) async throws -> String {
        var textRequest = URLRequest(url: url)
        textRequest.setValue(authorizationHeader, forHTTPHeaderField: "Authorization")
        if let token { textRequest.setValue(token, forHTTPHeaderField: "X-Emby-Token") }
        let (data, response) = try await URLSession.shared.data(for: textRequest)
        guard let http = response as? HTTPURLResponse, 200..<300 ~= http.statusCode else {
            throw JellyfinError.invalidResponse
        }
        return String(decoding: data, as: UTF8.self)
    }

    private func request(path: String, method: String = "GET", query: [URLQueryItem] = []) throws -> URLRequest {
        guard let url = makeURL(path: path, query: query) else { throw JellyfinError.invalidServer }
        var request = URLRequest(url: url)
        request.httpMethod = method
        request.timeoutInterval = 30
        request.setValue(authorizationHeader, forHTTPHeaderField: "Authorization")
        if let token { request.setValue(token, forHTTPHeaderField: "X-Emby-Token") }
        return request
    }

    private func makeURL(path: String, query: [URLQueryItem]) -> URL? {
        let normalizedPath = baseURL.path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        var components = URLComponents(url: baseURL, resolvingAgainstBaseURL: false)
        components?.path = "/" + ([normalizedPath, path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))]
            .filter { !$0.isEmpty }.joined(separator: "/"))
        components?.queryItems = query.filter { $0.value != nil }
        return components?.url
    }

    private var authorizationHeader: String {
        "MediaBrowser Client=\"\(Self.clientName)\", Device=\"Mac Studio\", DeviceId=\"home-cinema-m2-ultra\", Version=\"\(Self.version)\""
    }

    private func send<T: Decodable>(_ request: URLRequest, as type: T.Type) async throws -> T {
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw JellyfinError.invalidResponse }
        if http.statusCode == 401 { throw JellyfinError.invalidCredentials }
        guard 200..<300 ~= http.statusCode else {
            let body = String(data: data, encoding: .utf8) ?? ""
            throw JellyfinError.server(http.statusCode, body)
        }
        do {
            return try JSONDecoder().decode(type, from: data)
        } catch {
            throw JellyfinError.invalidResponse
        }
    }
}
