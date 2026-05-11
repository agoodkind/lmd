# Homebrew packaging

This directory ships a formula (`lmd.rb`) ready to drop into a Homebrew
tap repository. Publishing workflow:

1. Cut a git tag on the `lmd` repo, e.g. `v0.1.0`.
2. Download the tarball and compute its SHA-256:
   ```
   curl -L -o lmd-0.1.0.tar.gz \
     https://github.com/agoodkind/lmd/archive/refs/tags/v0.1.0.tar.gz
   shasum -a 256 lmd-0.1.0.tar.gz
   ```
3. Replace `REPLACE_WITH_RELEASE_TARBALL_SHA256` in `lmd.rb` with the
   computed hash; bump the `version` line; commit.
4. Push the formula into your tap repo, e.g.
   `github.com/agoodkind/homebrew-tap/Formula/lmd.rb`.
5. Users install via:
   ```
   brew tap agoodkind/tap
   brew install lmd
   ```

## Development install from source

Skip the tap entirely and build the current `HEAD`:

```
brew install --HEAD https://raw.githubusercontent.com/agoodkind/lmd/main/deploy/homebrew/lmd.rb
```

`brew audit --formula lmd` must pass before publishing to a tap.

## LaunchAgent note

Homebrew does not install into `~/Library/LaunchAgents/` automatically.
The formula drops the plist template under
`$(brew --prefix)/share/lmd/io.goodkind.lmd.serve.plist.example`; users
copy it into place and run `launchctl bootstrap` manually. The
`caveats` block in the formula spells this out.

## Open issue: metallib

The current `lmd.rb` runs `swift build -c release` only. That builds the
binaries but does not compile `default.metallib`, so `lmd-serve`
installed from this formula will crash on the first MLX inference call.
The formula needs to either invoke `tuist` plus `xcodebuild` for the
metallib half (matching `Tools/lmd-dev.swift install`) or ship a
pre-built `mlx-swift_Cmlx.bundle` in the release tarball. Until that is
resolved, `make install` from source is the supported path; see the
top-level `README.md`.
