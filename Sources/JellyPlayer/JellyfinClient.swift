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

    func catalogPage(userID: String, searchTerm: String, startIndex: Int, limit: Int) async throws -> JellyfinItemsResponse {
        if !searchTerm.isEmpty {
            let series = try await matchingSeries(userID: userID, searchTerm: searchTerm)
            if !series.isEmpty {
                return try await combinedSearchPage(
                    userID: userID,
                    searchTerm: searchTerm,
                    series: series,
                    startIndex: startIndex,
                    limit: limit
                )
            }
        }
        return try await itemPage(
            userID: userID,
            includeItemTypes: "Movie,Episode",
            searchTerm: searchTerm,
            startIndex: startIndex,
            limit: limit
        )
    }

    private func itemPage(
        userID: String,
        includeItemTypes: String,
        searchTerm: String,
        startIndex: Int,
        limit: Int
    ) async throws -> JellyfinItemsResponse {
        var query = [
            URLQueryItem(name: "UserId", value: userID),
            URLQueryItem(name: "IncludeItemTypes", value: includeItemTypes),
            URLQueryItem(name: "Recursive", value: "true"),
            URLQueryItem(name: "SortBy", value: "SortName"),
            URLQueryItem(name: "SortOrder", value: "Ascending"),
            URLQueryItem(name: "StartIndex", value: String(startIndex)),
            URLQueryItem(name: "Limit", value: String(limit)),
            URLQueryItem(name: "Fields", value: "MediaSources")
        ]
        if !searchTerm.isEmpty { query.append(URLQueryItem(name: "SearchTerm", value: searchTerm)) }
        let page = try await send(request(path: "/Items", query: query), as: JellyfinItemsResponse.self)
        let reportedTotal = page.totalRecordCount ?? (startIndex + page.items.count)
        let verifiedTotal = page.items.count < limit ? min(reportedTotal, startIndex + page.items.count) : reportedTotal
        return JellyfinItemsResponse(items: page.items, totalRecordCount: verifiedTotal)
    }

    private func combinedSearchPage(
        userID: String,
        searchTerm: String,
        series: [MediaItem],
        startIndex: Int,
        limit: Int
    ) async throws -> JellyfinItemsResponse {
        let movieCountPage = try await itemPage(
            userID: userID,
            includeItemTypes: "Movie",
            searchTerm: searchTerm,
            startIndex: 0,
            limit: 1
        )
        let movieTotal = movieCountPage.totalRecordCount ?? movieCountPage.items.count
        var items: [MediaItem] = []
        var remaining = limit
        if startIndex < movieTotal, remaining > 0 {
            let movies = try await itemPage(
                userID: userID,
                includeItemTypes: "Movie",
                searchTerm: searchTerm,
                startIndex: startIndex,
                limit: remaining
            )
            items.append(contentsOf: movies.items)
            remaining -= movies.items.count
        }
        let episodeOffset = max(0, startIndex - movieTotal)
        let episodes = try await episodePage(
            userID: userID,
            series: series,
            startIndex: episodeOffset,
            limit: remaining
        )
        items.append(contentsOf: episodes.items)
        return JellyfinItemsResponse(
            items: items,
            totalRecordCount: movieTotal + (episodes.totalRecordCount ?? episodes.items.count)
        )
    }

    private func matchingSeries(userID: String, searchTerm: String) async throws -> [MediaItem] {
        let query = [
            URLQueryItem(name: "UserId", value: userID),
            URLQueryItem(name: "IncludeItemTypes", value: "Series"),
            URLQueryItem(name: "Recursive", value: "true"),
            URLQueryItem(name: "SearchTerm", value: searchTerm),
            URLQueryItem(name: "SortBy", value: "SortName"),
            URLQueryItem(name: "SortOrder", value: "Ascending"),
            URLQueryItem(name: "Limit", value: "20")
        ]
        return try await send(request(path: "/Items", query: query), as: JellyfinItemsResponse.self).items
    }

    private func episodePage(
        userID: String,
        series: [MediaItem],
        startIndex: Int,
        limit: Int
    ) async throws -> JellyfinItemsResponse {
        var counts: [(id: String, count: Int)] = []
        for show in series {
            let countPage = try await seriesEpisodes(userID: userID, seriesID: show.id, startIndex: 0, limit: 1)
            counts.append((show.id, countPage.totalRecordCount ?? countPage.items.count))
        }
        let total = counts.reduce(0) { $0 + $1.count }
        var remainingOffset = startIndex
        var remainingLimit = limit
        var items: [MediaItem] = []
        for show in counts where remainingLimit > 0 {
            if remainingOffset >= show.count {
                remainingOffset -= show.count
                continue
            }
            let page = try await seriesEpisodes(
                userID: userID,
                seriesID: show.id,
                startIndex: remainingOffset,
                limit: remainingLimit
            )
            items.append(contentsOf: page.items)
            remainingLimit -= page.items.count
            remainingOffset = 0
        }
        return JellyfinItemsResponse(items: items, totalRecordCount: total)
    }

    private func seriesEpisodes(userID: String, seriesID: String, startIndex: Int, limit: Int) async throws -> JellyfinItemsResponse {
        let query = [
            URLQueryItem(name: "UserId", value: userID),
            URLQueryItem(name: "StartIndex", value: String(startIndex)),
            URLQueryItem(name: "Limit", value: String(limit)),
            URLQueryItem(name: "Fields", value: "MediaSources")
        ]
        return try await send(
            request(path: "/Shows/\(seriesID)/Episodes", query: query),
            as: JellyfinItemsResponse.self
        )
    }

    func item(userID: String, itemID: String) async throws -> MediaItem {
        try await send(
            request(
                path: "/Users/\(userID)/Items/\(itemID)",
                query: [URLQueryItem(name: "Fields", value: "Overview,MediaSources")]
            ),
            as: MediaItem.self
        )
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
