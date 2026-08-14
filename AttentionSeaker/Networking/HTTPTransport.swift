import Foundation

protocol HTTPTransporting {
    func data(for request: URLRequest) async throws -> (Data, HTTPURLResponse)
}

struct URLSessionTransport: HTTPTransporting {
    private let session: URLSession

    init(session: URLSession = URLSession(configuration: .ephemeral)) {
        self.session = session
    }

    func data(for request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        let (data, response) = try await session.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse else {
            throw HTTPTransportError.invalidResponse
        }
        return (data, httpResponse)
    }
}

enum HTTPTransportError: LocalizedError {
    case invalidResponse

    var errorDescription: String? {
        "The server returned an invalid response."
    }
}

