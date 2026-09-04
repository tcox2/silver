import Foundation

struct LoxoneClient: Sendable {
    private let server: URL
    private let authorization: String
    private let projectorPowerUUID: String
    private let amplifierVolumeUUID: String?

    init(
        server: String,
        username: String,
        password: String,
        projectorPowerUUID: String,
        amplifierVolumeUUID: String?
    ) throws {
        guard let url = URL(string: server), url.scheme?.lowercased() == "https",
              url.host != nil, !username.isEmpty, !password.isEmpty,
              !projectorPowerUUID.isEmpty else {
            throw LoxoneError.invalidConfiguration
        }
        self.server = url
        authorization = "Basic " + Data("\(username):\(password)".utf8).base64EncodedString()
        self.projectorPowerUUID = projectorPowerUUID
        self.amplifierVolumeUUID = amplifierVolumeUUID
    }

    var hasAmplifierVolume: Bool { amplifierVolumeUUID?.isEmpty == false }

    func setProjectorPower(on: Bool) async throws -> LoxoneCommandResult {
        let command = on ? "on" : "off"
        return try await request(uuid: projectorPowerUUID, command: command)
    }

    func currentAmplifierVolume() async throws -> Double {
        guard let amplifierVolumeUUID, !amplifierVolumeUUID.isEmpty else {
            throw LoxoneError.amplifierVolumeNotConfigured
        }
        let result = try await request(uuid: amplifierVolumeUUID, command: nil)
        guard let value = result.value.flatMap(Double.init), value.isFinite else {
            throw LoxoneError.invalidVolume
        }
        return value
    }

    func adjustAmplifierVolume(by delta: Double) async throws -> LoxoneVolumeResult {
        guard let amplifierVolumeUUID, !amplifierVolumeUUID.isEmpty else {
            throw LoxoneError.amplifierVolumeNotConfigured
        }
        let previous = try await currentAmplifierVolume()
        let requested = Self.adjustedVolume(current: previous, delta: delta)
        let response = try await request(
            uuid: amplifierVolumeUUID,
            command: String(format: "%.1f", requested)
        )
        let current = response.value.flatMap(Double.init) ?? requested
        return LoxoneVolumeResult(previousVolume: previous, currentVolume: current)
    }

    private func request(uuid: String, command: String?) async throws -> LoxoneCommandResult {
        let url = Self.commandURL(server: server, uuid: uuid, command: command)
        var request = URLRequest(url: url, timeoutInterval: 10)
        request.httpMethod = "GET"
        request.setValue(authorization, forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse, 200..<300 ~= http.statusCode else {
            throw LoxoneError.http((response as? HTTPURLResponse)?.statusCode ?? 0)
        }
        return try Self.parseCommandResponse(data, command: command ?? "read")
    }

    static func commandURL(server: URL, uuid: String, command: String?) -> URL {
        let controlURL = server
            .appendingPathComponent("jdev")
            .appendingPathComponent("sps")
            .appendingPathComponent("io")
            .appendingPathComponent(uuid)
        return command.map { controlURL.appendingPathComponent($0) } ?? controlURL
    }

    static func adjustedVolume(current: Double, delta: Double) -> Double {
        min(100, max(0, current + delta))
    }

    static func parseCommandResponse(_ data: Data, command: String) throws -> LoxoneCommandResult {
        guard let root = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let response = root["LL"] as? [String: Any] else {
            throw LoxoneError.invalidResponse
        }
        let code = response["Code"].map(String.init(describing:)) ?? ""
        guard code == "200" else { throw LoxoneError.commandRejected(code) }
        return LoxoneCommandResult(
            command: command,
            value: response["value"].map(String.init(describing:))
        )
    }
}

struct LoxoneCommandResult: Encodable, Sendable {
    let command: String
    let value: String?
}

struct LoxoneVolumeResult: Encodable, Sendable {
    let previousVolume: Double
    let currentVolume: Double
}

enum LoxoneError: LocalizedError {
    case invalidConfiguration
    case http(Int)
    case invalidResponse
    case commandRejected(String)
    case amplifierVolumeNotConfigured
    case invalidVolume

    var errorDescription: String? {
        switch self {
        case .invalidConfiguration:
            "Loxone control is not configured with a valid HTTPS endpoint, credentials, and Projector Power UUID."
        case let .http(status):
            "The Loxone Miniserver returned HTTP \(status)."
        case .invalidResponse:
            "The Loxone Miniserver returned an invalid response."
        case let .commandRejected(code):
            "The Loxone Miniserver rejected the command with code \(code)."
        case .amplifierVolumeNotConfigured:
            "The Loxone Lounge amplifier volume control is not configured."
        case .invalidVolume:
            "The Loxone Miniserver returned an invalid amplifier volume."
        }
    }
}
