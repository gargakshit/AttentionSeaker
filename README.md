# AttentionSeaker

AttentionSeaker is a macOS 15+ menu-bar app that shows open GitHub issues and pull requests that you authored, are assigned to, were mentioned on in comments, or were requested to review. The feed is ordered by the latest GitHub timeline activity, such as comments, reviews, commits, assignments, and labels. It uses your locally installed GitHub CLI for authentication and GraphQL access, and keeps only a last-good metadata snapshot in SwiftData.

The Settings window provides separate notification checkboxes for issues and pull requests. Notifications are off by default. You can opt into authored, mentioned, and assigned items for either kind, plus review requests for pull requests. macOS permission is requested when you first enable a notification type. Enabling a type treats the current snapshot as its baseline, so existing items do not produce a burst of alerts; matching items that appear in later successful refreshes can notify once. An item still produces at most one notification when it matches several selected reasons.

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
