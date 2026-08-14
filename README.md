# AttentionSeaker

AttentionSeaker is a macOS 15+ menu-bar app that shows open GitHub issues and pull requests that you authored, are assigned to, were mentioned on in comments, or were requested to review. It uses your locally installed GitHub CLI for authentication and GraphQL access, and keeps only a last-good metadata snapshot in SwiftData.

## Configure GitHub CLI

1. Install `gh`, for example with `brew install gh`.
2. Authenticate GitHub.com by running `gh auth login` in Terminal.
3. Confirm the active account with `gh auth status`.

AttentionSeaker invokes `gh api graphql` without a shell and sends GraphQL requests over standard input. It never reads or stores the token managed by `gh`. The scopes granted to `gh` determine whether private-repository results are available.

## Build and test

```sh
xcodebuild -project AttentionSeaker.xcodeproj \
  -scheme AttentionSeaker \
  -configuration Debug \
  -destination 'platform=macOS' \
  build

xcodebuild test \
  -project AttentionSeaker.xcodeproj \
  -scheme AttentionSeaker \
  -configuration Debug \
  -destination 'platform=macOS'
```

The app uses Hardened Runtime but not App Sandbox so it can execute the locally installed `gh` binary. The project uses only Apple frameworks. Signing, notarization, a final AppIcon, and release assets remain separate distribution tasks.

See [PRIVACY.md](PRIVACY.md) for the privacy policy.
