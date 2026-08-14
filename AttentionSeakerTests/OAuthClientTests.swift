import Foundation
import Testing
@testable import AttentionSeaker

@MainActor
struct OAuthClientTests {
    @Test
    func requestsADeviceCodeWithRepositoryScope() async throws {
        let response = #"{"device_code":"device","user_code":"ABCD-EFGH","verification_uri":"https://github.com/login/device","expires_in":900,"interval":5}"#
        let transport = StubHTTPTransport(stubs: [
            .init(data: Data(response.utf8), statusCode: 200, headers: [:]),
        ])
        let client = GitHubOAuthClient(transport: transport)

        let authorization = try await client.requestDeviceAuthorization(clientID: "client")

        #expect(authorization.userCode == "ABCD-EFGH")
        let body = String(data: transport.requests[0].httpBody ?? Data(), encoding: .utf8)
        #expect(body?.contains("scope=repo") == true)
        #expect(body?.contains("client_id=client") == true)
    }

    @Test
    func pollingHonorsPendingAndSlowDownBeforeSuccess() async throws {
        let pending = #"{"error":"authorization_pending"}"#
        let slowDown = #"{"error":"slow_down"}"#
        let success = #"{"access_token":"secret-token","scope":"repo","token_type":"bearer"}"#
        let transport = StubHTTPTransport(stubs: [pending, slowDown, success].map {
            .init(data: Data($0.utf8), statusCode: 200, headers: [:])
        })
        var sleeps: [TimeInterval] = []
        let client = GitHubOAuthClient(transport: transport) { interval in
            sleeps.append(interval)
        }
        let authorization = DeviceAuthorization(
            deviceCode: "device",
            userCode: "code",
            verificationURL: AppConfiguration.deviceAuthorizationURL,
            expiresAt: Date().addingTimeInterval(900),
            pollingInterval: 1
        )

        let token = try await client.waitForAccessToken(clientID: "client", authorization: authorization)

        #expect(token.value == "secret-token")
        #expect(token.scopes == ["repo"])
        #expect(sleeps == [1, 1, 6])
    }

    @Test
    func rejectsATokenWithoutRepositoryScope() async {
        let success = #"{"access_token":"secret-token","scope":"read:user","token_type":"bearer"}"#
        let transport = StubHTTPTransport(stubs: [
            .init(data: Data(success.utf8), statusCode: 200, headers: [:]),
        ])
        let client = GitHubOAuthClient(transport: transport) { _ in }
        let authorization = DeviceAuthorization(
            deviceCode: "device",
            userCode: "code",
            verificationURL: AppConfiguration.deviceAuthorizationURL,
            expiresAt: Date().addingTimeInterval(900),
            pollingInterval: 1
        )

        await #expect(throws: OAuthError.missingRepositoryScope) {
            try await client.waitForAccessToken(clientID: "client", authorization: authorization)
        }
    }

    @Test
    func handlesDenialExpiryAndCancellation() async {
        let denialTransport = StubHTTPTransport(stubs: [
            .init(data: Data(#"{"error":"access_denied"}"#.utf8), statusCode: 200, headers: [:]),
        ])
        let deniedClient = GitHubOAuthClient(transport: denialTransport) { _ in }
        let validAuthorization = authorization(expiresAt: Date().addingTimeInterval(900))

        await #expect(throws: OAuthError.accessDenied) {
            try await deniedClient.waitForAccessToken(
                clientID: "client",
                authorization: validAuthorization
            )
        }

        let expiredClient = GitHubOAuthClient(transport: StubHTTPTransport()) { _ in }
        await #expect(throws: OAuthError.expired) {
            try await expiredClient.waitForAccessToken(
                clientID: "client",
                authorization: authorization(expiresAt: Date().addingTimeInterval(-1))
            )
        }

        let cancelledClient = GitHubOAuthClient(transport: StubHTTPTransport()) { _ in }
        cancelledClient.cancel()
        await #expect(throws: CancellationError.self) {
            try await cancelledClient.waitForAccessToken(
                clientID: "client",
                authorization: validAuthorization
            )
        }
    }

    @Test
    func rejectsMalformedDeviceAndPollingResponses() async {
        let malformedDevice = StubHTTPTransport(stubs: [
            .init(data: Data(#"{"device_code":42}"#.utf8), statusCode: 200, headers: [:]),
        ])
        let deviceClient = GitHubOAuthClient(transport: malformedDevice)
        await #expect(throws: OAuthError.invalidResponse) {
            try await deviceClient.requestDeviceAuthorization(clientID: "client")
        }

        let malformedPolling = StubHTTPTransport(stubs: [
            .init(data: Data(#"{"access_token":42}"#.utf8), statusCode: 200, headers: [:]),
        ])
        let pollingClient = GitHubOAuthClient(transport: malformedPolling) { _ in }
        await #expect(throws: OAuthError.invalidResponse) {
            try await pollingClient.waitForAccessToken(
                clientID: "client",
                authorization: authorization(expiresAt: Date().addingTimeInterval(900))
            )
        }
    }

    private func authorization(expiresAt: Date) -> DeviceAuthorization {
        DeviceAuthorization(
            deviceCode: "device",
            userCode: "code",
            verificationURL: AppConfiguration.deviceAuthorizationURL,
            expiresAt: expiresAt,
            pollingInterval: 1
        )
    }
}
