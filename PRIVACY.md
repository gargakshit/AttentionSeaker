# AttentionSeaker Privacy Policy

AttentionSeaker is a local macOS menu-bar application. It does not operate a developer backend, include analytics or advertising, or sell or share personal information.

## GitHub access

Authentication happens directly between AttentionSeaker and GitHub. The OAuth access token is stored in the macOS Keychain and is sent only to GitHub over HTTPS. The app requests GitHub's `repo` OAuth scope so it can read issues and pull requests from private repositories visible to the signed-in account. AttentionSeaker performs read-only API operations.

## Local data

The app stores issue and pull-request metadata in its sandboxed SwiftData cache so the last successful result remains visible while offline. It does not cache issue bodies, comment text, source code, pull-request files, or review content.

The refresh interval is stored in app-local preferences. No app data is used for tracking.

## Deletion

Using **Sign Out and Clear Cache** removes the GitHub token from Keychain and deletes all locally cached GitHub metadata.

## Contact

Questions and updates are handled at <https://github.com/gargakshit/AttentionSeaker>.

