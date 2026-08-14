# AttentionSeaker Privacy Policy

AttentionSeaker is a local macOS menu-bar application. It does not operate a developer backend, include analytics or advertising, or sell or share personal information.

## GitHub access

AttentionSeaker invokes the GitHub CLI (`gh`) installed on your Mac and asks it to perform read-only GitHub GraphQL queries. Authentication and credential storage are managed entirely by `gh`; AttentionSeaker never reads, receives, stores, or logs your GitHub access token. The repositories available to the app are determined by the account and scopes configured in `gh`.

## Local data

The app stores issue and pull-request metadata in its sandboxed SwiftData cache so the last successful result remains visible while offline. It does not cache issue bodies, comment text, source code, pull-request files, or review content.

The refresh interval is stored in app-local preferences. No app data is used for tracking.

## Deletion

Using **Clear Cached GitHub Data** deletes all locally cached GitHub metadata. It does not sign out or modify the authentication used by `gh`; use `gh auth logout` separately if desired.

## Contact

Questions and updates are handled at <https://github.com/gargakshit/AttentionSeaker>.
