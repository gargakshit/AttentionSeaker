import Foundation

struct DeviceAuthorization: Equatable, Sendable {
    let deviceCode: String
    let userCode: String
    let verificationURL: URL
    let expiresAt: Date
    let pollingInterval: TimeInterval
}

struct OAuthAccessToken: Equatable, Sendable {
    let value: String
    let scopes: Set<String>
}

protocol OAuthAuthenticating: AnyObject {
    func requestDeviceAuthorization(clientID: String) async throws -> DeviceAuthorization
    func waitForAccessToken(clientID: String, authorization: DeviceAuthorization) async throws -> OAuthAccessToken
    func cancel()
}

@MainActor
final class GitHubOAuthClient: OAuthAuthenticating {
    private let transport: HTTPTransporting
    private let sleep: (TimeInterval) async throws -> Void
    private var isCancelled = false

    init(
        transport: HTTPTransporting,
        sleep: @escaping (TimeInterval) async throws -> Void = { interval in
            try await Task.sleep(for: .seconds(interval))
        }
    ) {
        self.transport = transport
        self.sleep = sleep
    }

    func requestDeviceAuthorization(clientID: String) async throws -> DeviceAuthorization {
        isCancelled = false
        var request = URLRequest(url: URL(string: "https://github.com/login/device/code")!)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.httpBody = formBody([
            "client_id": clientID,
            "scope": "repo",
        ])

        let (data, response) = try await transport.data(for: request)
        guard response.statusCode == 200 else {
            throw OAuthError.httpStatus(response.statusCode)
        }

        let payload: DeviceCodeResponse
        do {
            payload = try JSONDecoder().decode(DeviceCodeResponse.self, from: data)
        } catch {
            throw OAuthError.invalidResponse
        }
        guard let verificationURL = URL(string: payload.verificationURI),
              payload.expiresIn > 0,
              payload.interval > 0
        else {
            throw OAuthError.invalidResponse
        }

        return DeviceAuthorization(
            deviceCode: payload.deviceCode,
            userCode: payload.userCode,
            verificationURL: verificationURL,
            expiresAt: Date().addingTimeInterval(TimeInterval(payload.expiresIn)),
            pollingInterval: TimeInterval(payload.interval)
        )
    }

    func waitForAccessToken(clientID: String, authorization: DeviceAuthorization) async throws -> OAuthAccessToken {
        var pollingInterval = authorization.pollingInterval

        while Date() < authorization.expiresAt {
            try Task.checkCancellation()
            guard !isCancelled else {
                throw CancellationError()
            }

            try await sleep(pollingInterval)
            try Task.checkCancellation()
            guard !isCancelled else {
                throw CancellationError()
            }
            guard Date() < authorization.expiresAt else {
                throw OAuthError.expired
            }

            var request = URLRequest(url: URL(string: "https://github.com/login/oauth/access_token")!)
            request.httpMethod = "POST"
            request.setValue("application/json", forHTTPHeaderField: "Accept")
            request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
            request.httpBody = formBody([
                "client_id": clientID,
                "device_code": authorization.deviceCode,
                "grant_type": "urn:ietf:params:oauth:grant-type:device_code",
            ])

            let (data, response) = try await transport.data(for: request)
            guard response.statusCode == 200 else {
                throw OAuthError.httpStatus(response.statusCode)
            }

            let payload: AccessTokenResponse
            do {
                payload = try JSONDecoder().decode(AccessTokenResponse.self, from: data)
            } catch {
                throw OAuthError.invalidResponse
            }
            if let token = payload.accessToken {
                let scopes = Set(
                    (payload.scope ?? "")
                        .split(whereSeparator: { $0 == "," || $0 == " " })
                        .map(String.init)
                )
                guard scopes.contains("repo") else {
                    throw OAuthError.missingRepositoryScope
                }
                return OAuthAccessToken(value: token, scopes: scopes)
            }

            switch payload.error {
            case "authorization_pending":
                continue
            case "slow_down":
                pollingInterval += 5
            case "access_denied":
                throw OAuthError.accessDenied
            case "expired_token":
                throw OAuthError.expired
            case "incorrect_device_code":
                throw OAuthError.invalidDeviceCode
            case "device_flow_disabled":
                throw OAuthError.deviceFlowDisabled
            case .some(let error):
                throw OAuthError.server(payload.errorDescription ?? error)
            case .none:
                throw OAuthError.invalidResponse
            }
        }

        throw OAuthError.expired
    }

    func cancel() {
        isCancelled = true
    }

    private func formBody(_ values: [String: String]) -> Data? {
        var components = URLComponents()
        components.queryItems = values
            .sorted(by: { $0.key < $1.key })
            .map { URLQueryItem(name: $0.key, value: $0.value) }
        return components.percentEncodedQuery?.data(using: .utf8)
    }
}

enum OAuthError: LocalizedError, Equatable {
    case httpStatus(Int)
    case invalidResponse
    case accessDenied
    case expired
    case invalidDeviceCode
    case deviceFlowDisabled
    case missingRepositoryScope
    case server(String)

    var errorDescription: String? {
        switch self {
        case .httpStatus(let status):
            return "GitHub authentication failed with HTTP status \(status)."
        case .invalidResponse:
            return "GitHub returned an invalid authentication response."
        case .accessDenied:
            return "GitHub authorization was denied."
        case .expired:
            return "The GitHub device code expired. Try connecting again."
        case .invalidDeviceCode:
            return "GitHub rejected the device code. Try connecting again."
        case .deviceFlowDisabled:
            return "Device Flow is not enabled for this GitHub OAuth App."
        case .missingRepositoryScope:
            return "Private repository access was not granted. Reconnect and approve the repo scope."
        case .server(let message):
            return message
        }
    }
}

private struct DeviceCodeResponse: Decodable {
    let deviceCode: String
    let userCode: String
    let verificationURI: String
    let expiresIn: Int
    let interval: Int

    enum CodingKeys: String, CodingKey {
        case deviceCode = "device_code"
        case userCode = "user_code"
        case verificationURI = "verification_uri"
        case expiresIn = "expires_in"
        case interval
    }
}

private struct AccessTokenResponse: Decodable {
    let accessToken: String?
    let scope: String?
    let error: String?
    let errorDescription: String?

    enum CodingKeys: String, CodingKey {
        case accessToken = "access_token"
        case scope
        case error
        case errorDescription = "error_description"
    }
}
