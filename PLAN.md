# Lyra — Porting Plan

Lyra is a native macOS Pandora client that replicates the feature set of
[Hermes](../Hermes) without any Intel-only dependencies, so it runs natively on
Apple silicon (no Rosetta) and on Intel Macs from a single universal binary.

## Why Hermes needs Rosetta today

| Hermes component | Problem | Lyra replacement |
| --- | --- | --- |
| `Frameworks/Growl.framework` | Prebuilt binary, i386 + x86_64 only; Growl is dead | `UserNotifications` (`UNUserNotificationCenter`) |
| `Frameworks/Sparkle.framework` (1.x) | Prebuilt binary, x86_64 only; DSA signatures | Sparkle 2.x via Swift Package Manager (universal, EdDSA) — Phase 5 |
| `ImportedSources/SPMediaKeyTap` | `CGEventTap` hack, needs Accessibility permission | `MPRemoteCommandCenter` + `MPNowPlayingInfoCenter` |
| `ImportedSources/blowfish` | Hand-rolled C Blowfish | `CommonCrypto` Blowfish ECB (`PandoraCrypto`) |
| `Sources/AudioStreamer` | `AudioQueue` + `CFReadStream` streamer | `AVPlayer` / `AVQueuePlayer` |
| `Sources/URLConnection`, `NetworkConnection` | `CFReadStream`, `SCNetworkReachability` | `URLSession` async/await, `NWPathMonitor` |
| `Sources/Integration/Keychain` | Deprecated `SecKeychain*` APIs | `SecItem*` generic-password items |
| `ImportedSources/FMEngine` (Last.fm) | `NSURLConnection` | `URLSession` client in LyraKit |
| `NSDrawer`, custom cells, `MainMenu.xib` | Deprecated AppKit UI | SwiftUI (`NavigationSplitView`, `MenuBarExtra`, `Settings`) |
| `Carbon.framework` hot keys | Legacy | `KeyboardShortcuts`-style `NSEvent` monitors / app shortcuts |

## Architecture

```
Lyra.xcodeproj
├── Lyra            (macOS app, SwiftUI + AppKit where needed)
│   ├── App lifecycle, windows, MenuBarExtra, Settings
│   ├── AppleScript bridge (Lyra.sdef + NSScriptCommand subclasses)
│   └── Now Playing / remote commands / notifications
├── LyraKit         (macOS framework, no UI)
│   ├── Pandora/    JSON API v5 client, partner devices, Blowfish crypto
│   ├── Models/     Station, Song, SearchResult, Feedback
│   ├── Playback/   AVPlayer-based player + playlist prefetch
│   └── Services/   Keychain, Last.fm scrobbler, reachability
├── LyraKitTests    (unit tests, Swift Testing)
└── LyraUITests     (UI smoke tests, XCTest)
```

Build settings shared by all targets:

- **LyraKit is a static framework** linked into the app binary. A dynamic one fails
  library validation under hardened runtime when ad-hoc signed (no Team ID).
- **Architectures:** `$(ARCHS_STANDARD)` → `arm64 x86_64` universal for Release;
  Debug builds only the active arch. No Rosetta at any point.
- **Deployment target:** macOS 14.0 (Sonoma) — gives us `@Observable`,
  modern `MenuBarExtra`, and `SettingsLink`.
- **Language:** Swift 6 with strict concurrency.
- **Hardened runtime + App Sandbox** (`network.client` only).
- Xcode 16+ project format with folder-synchronized groups: drop a file into
  `Lyra/`, `LyraKit/`, etc. and it is part of that target — no pbxproj edits.

## Phases

### Phase 0 — Scaffold (this commit)
- [x] Xcode project with `Lyra`, `LyraKit`, `LyraKitTests`, `LyraUITests`
- [x] Shared `Lyra` scheme, `Makefile` wrapper (`make`, `make run`, `make test`, `make verify-arch`)
- [x] `PandoraDevice` partner credentials, `PandoraCrypto` (Blowfish via CommonCrypto) with tests
      verified against Hermes's C implementation
- [x] Model and API-method stubs; placeholder SwiftUI UI

### Phase 1 — Pandora API core (LyraKit) ✅
- `PandoraClient` actor: request building (`/services/json/?method=…&partner_id=…&auth_token=…&user_id=…`),
  TLS vs. non-TLS methods, encrypted bodies, `syncTime` handling.
- `auth.partnerLogin` → `auth.userLogin`, with Hermes's fallback to the desktop
  device on `INVALID_PARTNER_LOGIN`; auto re-login on `INVALID_AUTH_TOKEN`.
- `user.getStationList`, `station.getPlaylist`, `station.addFeedback`,
  `station.deleteFeedback`, `user.sleepSong`.
- Keychain credential storage (`SecItem*`).
- Tests with a `URLProtocol` stub replaying recorded JSON.

### Phase 2 — Playback ✅
- `Player` (`@Observable`) on `AVQueuePlayer`: prefetch next playlist when
  the queue runs low, skip, pause/resume, volume, progress, audio quality pref
  (low/medium/high per Hermes).
- Handle expired track URLs (Pandora links time out) by refetching.
- `MPNowPlayingInfoCenter` + `MPRemoteCommandCenter` (replaces SPMediaKeyTap).

### Phase 3 — UI parity ✅
- Login sheet, station list (sort by name/date, filter), now-playing view with
  art, like/dislike/tired, volume, progress.
- History list with like/dislike from history; open song/artist/album on Pandora.
- Station management: create (search + genre stations), rename, delete,
  edit seeds & feedback (`station.getStation`, `addMusic`, `deleteMusic`, …).
- Menu bar extra with play/pause/skip and optional "menu bar only" mode
  (Hermes's `LSUIElement` toggle → `NSApp.setActivationPolicy`).
- Settings window: account, playback, notifications, Last.fm, proxy.
- Keyboard shortcuts per `Hermes/Documentation/KeyboardShortcuts.md`.

### Phase 4 — Integrations
- Notifications via `UserNotifications` (new song / resume, with album art and
  like/skip actions).
- Distributed notification `hermes.song`-compatible (`lyra.song`) for 3rd-party tools.
- AppleScript: port `Hermes.sdef` command set (play, pause, playpause, next song,
  thumbs up/down, tired of song, volume commands, current station/song properties).
- Last.fm scrobbling (`auth.getSession`, `track.scrobble`, `track.love`).

### Phase 5 — Distribution
- Sparkle 2 via SPM, EdDSA-signed appcast.
- Developer ID signing + notarization script (replaces `Scripts/*.sh`).
- `lipo -archs` check in CI to guarantee `arm64 x86_64`.

### Known gaps after Phase 3
- Not yet verified against the live Pandora service (needs a real account); the wire
  format is covered by `PandoraClientTransportTests` against a fake tuner.
- Proxy settings and an explicit "toolbar hide" toggle from Hermes are not ported.

## Open questions
- Sparkle vs. Mac App Store only? (Sandbox + Sparkle 2 needs its XPC services.)
- Proxy support (Hermes supports HTTP/SOCKS proxy) — `URLSessionConfiguration.connectionProxyDictionary`.
- Bundle identifier: currently `com.velpeo.Lyra`; set `DEVELOPMENT_TEAM` once known.
