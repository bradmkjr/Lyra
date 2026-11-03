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
