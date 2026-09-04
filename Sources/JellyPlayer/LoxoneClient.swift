import Foundation

struct LoxoneClient: Sendable {
    private let server: URL
    private let authorization: String
    private let projectorPowerUUID: String

    init(server: String, username: String, password: String, projectorPowerUUID: String) throws {
        guard let url = URL(string: server), url.scheme?.lowercased() == "https",
              url.host != nil, !username.isEmpty, !password.isEmpty,
              !projectorPowerUUID.isEmpty else {
            throw LoxoneError.invalidConfiguration
        }
        self.server = url
        authorization = "Basic " + Data("\(username):\(password)".utf8).base64EncodedString()
        self.projectorPowerUUID = projectorPowerUUID
    }

    func setProjectorPower(on: Bool) async throws -> LoxoneCommandResult {
        let command = on ? "on" : "off"
        let url = Self.commandURL(server: server, uuid: projectorPowerUUID, command: command)
        var request = URLRequest(url: url, timeoutInterval: 10)
        request.httpMethod = "GET"
        request.setValue(authorization, forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse, 200..<300 ~= http.statusCode else {
            throw LoxoneError.http((response as? HTTPURLResponse)?.statusCode ?? 0)
        }
        return try Self.parseCommandResponse(data, command: command)
    }

    static func commandURL(server: URL, uuid: String, command: String) -> URL {
        server
            .appendingPathComponent("jdev")
            .appendingPathComponent("sps")
            .appendingPathComponent("io")
            .appendingPathComponent(uuid)
            .appendingPathComponent(command)
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

enum LoxoneError: LocalizedError {
    case invalidConfiguration
    case http(Int)
    case invalidResponse
    case commandRejected(String)

    var errorDescription: String? {
        switch self {
        case .invalidConfiguration:
            "Loxone control is not configured with a valid HTTPS endpoint, credentials, and Projector Power UUID."
        case let .http(status):
            "The Loxone Miniserver returned HTTP \(status)."
        case .invalidResponse:
            "The Loxone Miniserver returned an invalid response."
        case let .commandRejected(code):
            "The Loxone Miniserver rejected the projector command with code \(code)."
        }
    }
}
