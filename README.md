# AttentionSeaker

AttentionSeaker is a macOS 15+ menu-bar app that shows open GitHub issues and pull requests that you authored, are assigned to, were mentioned on in comments, or were requested to review.

It uses the GitHub CLI behind the scenes. I built this because I got tired of losing track of my GitHub.

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

