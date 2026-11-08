# Lyra
Compact macOS Pandora client that doesn’t use Flash or Rosetta

A Swift/SwiftUI successor to [Hermes](https://github.com/HermesApp/Hermes), built as a
universal (arm64 + x86_64) binary. See [PLAN.md](PLAN.md) for the porting roadmap.

## Building

Requires Xcode 16 or later; runs on macOS 14+.

```sh
make              # Debug build
make run          # build and launch
make test         # LyraKit unit tests
make verify-arch  # Release build + check every binary is arm64 + x86_64
```

Or open `Lyra.xcodeproj` and use the **Lyra** scheme.

## Scripting and integrations

Lyra keeps Hermes's AppleScript dictionary (same command codes), so Hermes scripts work
after changing the target to `"Lyra"`:

```applescript
tell application "Lyra"
  playpause
  next song
  thumbs up
  set playback volume to 60
  get title of current song
  set current station to station "Shuffle"
end tell
```

When a song starts, Lyra posts a `lyra.song` distributed notification. Because Lyra is
sandboxed it can't attach `userInfo`, so the notification's `object` is a JSON string
with Hermes's `hermes.song` keys (`title`, `artist`, `album`, `art`, `stationId`,
`nrating`, `titleUrl`, `artistUrl`, `albumUrl`, `token`).
