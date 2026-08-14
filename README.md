# AttentionSeaker

AttentionSeaker is a sandboxed macOS 15+ menu-bar app that shows open GitHub issues and pull requests that you authored, are assigned to, were mentioned on in comments, or were requested to review. It talks directly to GitHub, stores the OAuth token in Keychain, and keeps only a last-good metadata snapshot in SwiftData.

## Configure GitHub OAuth

1. Create a GitHub OAuth App named `AttentionSeaker`.
2. Set both its homepage and callback URL to `https://github.com/gargakshit/AttentionSeaker`.
3. Enable Device Flow.
4. In the `AttentionSeaker` target's build settings, replace `REPLACE_WITH_GITHUB_OAUTH_CLIENT_ID` in `GITHUB_OAUTH_CLIENT_ID` with the app's public client ID for both Debug and Release.

No client secret belongs in this project. The app requests the broad `repo` scope so private-repository results can be included, but it makes read-only API calls.

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

The project uses only Apple frameworks and remains App Sandbox compatible. A final AppIcon, signed archive, screenshots, live support/privacy URLs, and App Store Connect metadata are separate release tasks.

See [PRIVACY.md](PRIVACY.md) for the privacy policy.
