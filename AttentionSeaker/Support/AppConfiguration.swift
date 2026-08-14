import Foundation

struct AppConfiguration: Sendable {
    static let githubHomepageURL = URL(string: "https://github.com/gargakshit/AttentionSeaker")!
    static let privacyPolicyURL = URL(string: "https://github.com/gargakshit/AttentionSeaker/blob/main/PRIVACY.md")!
    static let deviceAuthorizationURL = URL(string: "https://github.com/login/device")!

    let githubOAuthClientID: String?

    init(bundle: Bundle = .main) {
        let rawValue = bundle.object(forInfoDictionaryKey: "GitHubOAuthClientID") as? String
        let value = rawValue?.trimmingCharacters(in: .whitespacesAndNewlines)
        githubOAuthClientID = value.flatMap { candidate in
            guard !candidate.isEmpty,
                  !candidate.contains("$("),
                  candidate != "REPLACE_WITH_GITHUB_OAUTH_CLIENT_ID"
            else {
                return nil
            }
            return candidate
        }
    }

    init(githubOAuthClientID: String?) {
        self.githubOAuthClientID = githubOAuthClientID
    }
}

