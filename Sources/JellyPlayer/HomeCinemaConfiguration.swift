import Foundation

struct HomeCinemaConfiguration: Decodable, Sendable {
    let jellyfinURL: String
    let username: String
    let password: String
    let outputModes: [ConfiguredOutputMode]
    let youtubeURL: String?
    let youtubeUsername: String?
    let youtubePassword: String?

    enum CodingKeys: String, CodingKey { case jellyfinURL, username, password, outputModes, youtubeURL, youtubeUsername, youtubePassword }

    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        jellyfinURL = try values.decode(String.self, forKey: .jellyfinURL)
        username = try values.decode(String.self, forKey: .username)
        password = try values.decode(String.self, forKey: .password)
        outputModes = try values.decodeIfPresent([ConfiguredOutputMode].self, forKey: .outputModes) ?? []
        youtubeURL = try values.decodeIfPresent(String.self, forKey: .youtubeURL)
        youtubeUsername = try values.decodeIfPresent(String.self, forKey: .youtubeUsername)
        youtubePassword = try values.decodeIfPresent(String.self, forKey: .youtubePassword)
    }

    static func load() throws -> Self {
        let environment = ProcessInfo.processInfo.environment
        let applicationSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Silver", isDirectory: true)
            .appendingPathComponent("config.json")
            .path
        let path = environment["HOME_CINEMA_CONFIG"]
            ?? [applicationSupport, FileManager.default.currentDirectoryPath + "/config.json"]
                .first(where: { FileManager.default.fileExists(atPath: $0) })
            ?? applicationSupport
        guard FileManager.default.fileExists(atPath: path) else {
            SilverLog.error("Configuration missing path=\(path)")
            throw ConfigurationError.missing(path)
        }
        do {
            let data = try Data(contentsOf: URL(fileURLWithPath: path))
            let configuration = try JSONDecoder().decode(Self.self, from: data)
            guard !configuration.jellyfinURL.isEmpty, !configuration.username.isEmpty else {
                throw ConfigurationError.incomplete
            }
            SilverLog.info("Loaded configuration path=\(path) outputModes=\(configuration.outputModes.count)")
            return configuration
        } catch let error as ConfigurationError {
            throw error
        } catch {
            throw ConfigurationError.invalid(path)
        }
    }
}

struct ConfiguredOutputMode: Decodable, Sendable {
    let label: String
    let mediaWidth: Int
    let mediaHeight: Int
    let mediaFrameRate: Double
    let mediaDynamicRange: String
    let displayWidth: Int
    let displayHeight: Int
    let displayRefreshRate: Double
    let force: Bool

    func matches(width: Int, height: Int, frameRate: Double, hdr: Bool) -> Bool {
        mediaWidth == width && mediaHeight == height
            && abs(mediaFrameRate - frameRate) < 0.01
            && (mediaDynamicRange.lowercased() == "hdr") == hdr
    }

    func contains(width: Int, height: Int, frameRate: Double, hdr: Bool) -> Bool {
        mediaWidth >= width && mediaHeight >= height
            && displayWidth >= width && displayHeight >= height
            && abs(mediaFrameRate - frameRate) < 0.01
            && (mediaDynamicRange.lowercased() == "hdr") == hdr
    }
}

enum ConfigurationError: LocalizedError {
    case missing(String)
    case invalid(String)
    case incomplete

    var errorDescription: String? {
        switch self {
        case let .missing(path): "Configuration file not found at \(path)."
        case let .invalid(path): "Configuration file at \(path) is not valid JSON."
        case .incomplete: "Configuration requires jellyfinURL, username, and password."
        }
    }
}
