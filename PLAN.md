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
│   └── Services/   Keychain, notifications
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
- `Player` (`@Observable`) on `AVPlayer` with its own queue: prefetch next playlist when
  the queue runs low, skip, pause/resume, volume, progress, audio quality pref
  (low/medium/high per Hermes).
- Audio URLs stay on HTTP: the `audio-*.pandora.com` stream hosts don't serve HTTPS, so
  `Lyra-Info.plist` sets `NSAllowsArbitraryLoadsForMedia` (AVFoundation only; API calls and
  artwork stay HTTPS). Streams have no file extension, so each carries its format and
  `AVURLAssetOverrideMIMETypeKey` tells AVFoundation `audio/aac` (ADTS) or `audio/mpeg`.
- A song that won't load tries its other streams before being skipped; skipping drops the
  queued fragment (Pandora links expire) and refetches. Failures log to
  `log stream --predicate 'subsystem == "com.velpeo.Lyra"'`.
- `MPNowPlayingInfoCenter` + `MPRemoteCommandCenter` (replaces SPMediaKeyTap).

### Phase 3 — UI parity ✅
- Login sheet, station list (sort by name/date, filter), now-playing view with
  art, like/dislike/tired, volume, progress.
- History list with like/dislike from history; open song/artist/album on Pandora.
- Station management: create (search + genre stations), rename, delete,
  edit seeds & feedback (`station.getStation`, `addMusic`, `deleteMusic`, …).
- Menu bar extra with play/pause/skip and optional "menu bar only" mode
  (Hermes's `LSUIElement` toggle → `NSApp.setActivationPolicy`).
- Settings window: account, playback, notifications, general.
- Keyboard shortcuts per `Hermes/Documentation/KeyboardShortcuts.md`.

### Phase 4 — Integrations ✅ (except Last.fm)
- Notifications via `UserNotifications` (new song / resume, with album art and
  Like/Dislike/Skip actions).
- Distributed notification `lyra.song` with Hermes's `hermes.song` keys. Sandboxed apps
  can't send `userInfo`, so the payload is a JSON string in the notification's `object`.
- AppleScript: `Lyra/Lyra.sdef` ports `Hermes.sdef` with the same four-char codes (play,
  pause, playpause, next song, thumbs up/down, tired of song, volume commands, current
  station/song properties).
- Deferred: Last.fm scrobbling (`auth.getMobileSession`, `track.scrobble`, `track.love`);
  needs a Last.fm API key and secret.

### Phase 5 — Distribution
- Sparkle 2 via SPM, EdDSA-signed appcast.
- Developer ID signing + notarization script.
- `lipo -archs` check in CI to guarantee `arm64 x86_64`.

### Known gaps
- Playback fixes (HTTP media, format hints) still need confirming against a live account;
  the wire format is covered by `PandoraClientTransportTests` against a fake tuner.
- Proxy settings and an explicit "toolbar hide" toggle from Hermes are not ported.

## Whole-house audio (branch `feature/whole-house-audio`)
- **Local outputs, done:** tick several Core Audio outputs (Mac mini speakers, Studio
  Display, USB/HDMI). Lyra builds a private multi-output aggregate device (`OutputRouter`)
  with drift compensation, and pads faster devices with extra output latency so every room
  hears the same moment. Per-room volume uses each device's hardware volume. Choice
  persists; unplugged outputs rejoin when reconnected.
- **AirPlay rooms (tested 2026-11-08 with an Apple TV):** the player-level AirPlay picker
  (`AVRoutePickerView`) is a dead end for Pandora. It hands the stream URL to the receiver,
  which can't decode the extension-less raw AAC (MP3 handoff hung too), and with handoff
  off macOS ignores the picked route. Instead, once a receiver is chosen in Control Center
  → Sound, macOS exposes it as a Core Audio output (transport `airp`) reporting 2.000 s of
  stream latency. It joins Lyra's multi-output device like any speaker; the router pads the
  local outputs by the latency difference, and the Mac decodes so formats don't matter.
  `allowsExternalPlayback` stays off so the player never hands off its URL.
- **Verified 2026-11-08:** Apple TV + Studio Display play in sync by ear in Lyra's group.
- **To verify:** whether the AirPlay output stays available (and keeps playing in Lyra's
  group) after the system output is switched back to the Mac's speakers.
- **Later:** several AirPlay receivers at once, if macOS exposes more than one AirPlay
  output at a time.

### Lyra's own AirPlay sender (multi-room)
macOS gives apps one AirPlay receiver at a time, so Lyra speaks AirPlay itself. Survey of
the home network (2026-11-08):

| Receiver | Model | AirPlay | `OPTIONS` |
|---|---|---|---|
| Apple TV | AppleTV3,2 | 1 only (AirTunes 220.68) | 200, open |
| Apple TV (2) | AppleTV3,1 | 1 only (AirTunes 220.68) | 200, open |
| STR-ZA810ES (Sony) | MSA4G-Z9 | 1 only (AirTunes 190.9) | 200, open |
| MacBook Air | Mac14,15 | macOS receiver, accepts 1 (AirTunes 870) | 403 until "Allow AirPlay for: Anyone" |

All advertise `_raop._tcp` with `et=0` (unencrypted) and `cn=1` (Apple Lossless), so Lyra
uses **AirPlay 1 (RAOP)**: no pairing, no AirPlay 2 cryptography, works with all of them.

Design (`LyraKit/AirPlay/`):
- **Discovery:** `NWBrowser` on `_raop._tcp` (TXT gives `cn`, `et`, `pw`, model).
- **Session per receiver:** RTSP over TCP: `OPTIONS` → `ANNOUNCE` (SDP, ALAC 352
  frames/packet, 44.1 kHz/16-bit/stereo) → `SETUP` (returns audio/control/timing ports)
  → `RECORD`; `SET_PARAMETER volume` (dB, -30…0) for per-receiver volume; `FLUSH` on
  skip/pause; `TEARDOWN`.
- **Audio:** RTP over UDP, ALAC "escape" (uncompressed) frames: no codec needed.
- **Clock:** Lyra answers each receiver's NTP-style timing requests and sends RTP↔NTP
  sync packets every second. A receiver plays frame *R* at the NTP time the sync packets
  map it to, so **per-receiver delay** is an offset in that mapping; all rooms share one
  clock.
- **Source:** an `MTAudioProcessingTap` on the player item captures decoded PCM. While
  AirPlay rooms are active, local speakers are fed the same PCM, delayed to the same clock,
  so this Mac stays in sync too.
- Needs `com.apple.security.network.server` (receivers send timing/resend requests to Lyra)
  and `NSBonjourServices` + `NSLocalNetworkUsageDescription`.

Milestones: (1) discovery + list in Speakers; (2) session + test tone to one receiver;
(3) stream Lyra's music with local speakers in sync; (4) all receivers together with
per-receiver volume and delay, resend handling, flush on skip/pause;
(5) microphone auto-calibration.

**Progress (2026-11-08): milestone 2 done.** Lyra's own AirPlay 1 sender plays a test tone
on the Great Room Apple TV (verified by ear). The fixes that got it there, all matching
pyatv's working sender:
- **Sync from the declared control port.** Receivers ignore sync packets that don't come
  from the `control_port` given in SETUP, so one BSD UDP socket (`ControlSocket`) both
  sends sync and answers resend requests. This was the final blocker.
- **Raw PCM (`L16`)** for receivers listing `cn=0` (Apple TVs, Sony); Apple's ALAC encoder
  only for receivers without PCM. One format per stream.
- UDP bound to the RTSP connection's local address (two interfaces on one subnet here).
- pyatv's start sequence: GET /info, first sync before RECORD, RECORD then FLUSH with
  RTP-Info, POST /feedback, 1.5 s latency.

**Milestone 3 done (2026-11-08, verified by ear: Great Room Apple TV in sync with this Mac):** `PCMTap` (an
`MTAudioProcessingTap` on each player item) copies decoded audio to `AirPlayStreamer.input`
and, while any room is connected, delays this Mac's own output by the 1.5 s AirPlay
buffer so local speakers stay in sync. The streamer pumps the pipe every 10 ms and
flushes/re-anchors when audio timing jumps by >250 ms (pause, skip, stall). Rooms are
ticked in Speakers → AirPlay Rooms (persisted, reconnect when found); volume and delay
sliders appear only for ticked rooms.

**Milestone 5 (code done, 2026-11-08, needs a live check on the MacBook Air):** each ticked
room has **Calibrate**. Lyra pauses music, starts the microphone (`MicrophoneRecorder`,
stamped on the same uptime clock as the AirPlay audio, input latency removed), plays three
600 Hz→6 kHz chirps 1 s apart to that room only (`AirPlayStreamer.play(samples:only:)`),
finds each by cross-correlation (`ArrivalDetector`, vDSP), and sets the room's delay by
the median error so it sounds exactly when the clock says. Disabled without a microphone
(Mac mini); manual sliders always work. Unit tests cover the detector in noise.

**Fixed (2026-11-08):** crash "Can't remove more items from a collection" when a test tone
ran during music with three rooms connected: actor reentrancy in `AirPlayStreamer`
(`enqueue`/`sendPacket` mutated state across awaits). Packets are now taken and sequence
numbers claimed before awaiting; servers are created once even when rooms connect together
(they had been created three times); duplicate connects are guarded; the music pump holds
off while a test tone or calibration chirp plays. **Next session:** re-run the test tone
with several rooms, then calibration live (Great Room, Family Room, Kitchen, Sony).

**Fixed (2026-11-08 ~16:03): AirPlay silent with Wi-Fi on.** Not a code regression: the
control socket was bound to INADDR_ANY, so with two interfaces on one subnet (en0 wired,
en1 Wi-Fi) sync packets could leave from a different address than the RTSP session and
receivers ignored them. It only worked while Wi-Fi was off. Now one `ControlSocket` per
local address, bound to the address the session's RTSP connection uses
(`RAOPSession.open()` first). Verified by ear on Great Room with Wi-Fi on. The
`X-Apple-Client-Name` header stays out for now (re-add with an ASCII-only name).

**Next session:** calibration live (Great Room, Family Room, Kitchen, Sony); several rooms
playing music together; AirPlay 2 for Mac receivers only if wanted.

**Finding: macOS's AirPlay Receiver only plays AirPlay 2.** It accepts an AirPlay 1
session but discards the audio. Verified with pyatv 0.18 against the MacBook Air: forced
AirPlay 1 → connection dropped in setup; AirPlay 2 (HAP transient pairing, PIN 3939) →
the tone plays. So Lyra's silence on the Air isn't a bug in its AirPlay 1 sender.

**Next:** (a) tone on the Sony, Family Room and third Apple TV, then several rooms at once;
(b) milestone 3, stream Lyra's music; (c) new milestone: AirPlay 2 for Mac receivers, following pyatv
(`protocols/raop/protocols/airplayv2.py`, `auth/hap_transient.py`): transient pairing
(SRP-6a 3072/SHA-512, user "Pair-Setup", PIN 3939), ChaCha20-Poly1305 encrypted RTSP,
binary-plist SETUP, encrypted RTP audio. Live test harness:
`TEST_RUNNER_LYRA_AIRPLAY_TARGET='<MAC>@<Name>' make test` (`AirPlayLiveTests`).

**Auto-calibration (milestone 5):** Lyra knows exactly when each frame should sound, so
it plays a short, distinct chirp through one room at a scheduled moment, records it with
the Mac's microphone, and cross-correlates to find when it actually arrived. That room's
delay becomes `target - measured`, so every room sounds at the same instant. Rooms can be
calibrated one at a time (stand in a room with the MacBook Air, tap Calibrate). Results go
into the same per-receiver delay sliders, which stay manual for when Lyra runs on the Mac
mini. Needs `com.apple.security.device.audio-input` and `NSMicrophoneUsageDescription`,
used only while calibrating.

## Open questions
- Sparkle vs. Mac App Store only? (Sandbox + Sparkle 2 needs its XPC services.)
- Proxy support (Hermes supports HTTP/SOCKS proxy) — `URLSessionConfiguration.connectionProxyDictionary`.
- Bundle identifier: currently `com.velpeo.Lyra`; set `DEVELOPMENT_TEAM` once known.
