# μDLNA server development

## Build and run

Requires macOS and Xcode Command Line Tools with Swift 5.9 or later.
Sparkle is the only external dependency; Swift Package Manager downloads it.

```sh
./build-app.sh
open .build/microDLNA.app
```

The app uses `~/Movies` and automatically selects a LAN IPv4 address.
To override the folder and address, quit any running instance first:

```sh
open .build/microDLNA.app --args "$HOME/Movies" 192.168.1.20
```

## Checks

```sh
Tests/BrowseRegression/run.sh
.build/microDLNA.app/Contents/MacOS/microdlna --self-test
```

## DMG and releases

```sh
./build-dmg.sh      # Universal DMG for Apple silicon and Intel
./build-release.sh  # DMG + signed Sparkle appcast; verifies the feed signature
```

Output: `.build/releases/v<VERSION>/`. For each release:

1. Increase `CFBundleShortVersionString` and `CFBundleVersion` in `App/Info.plist`.
2. Run `./build-release.sh` on the Mac holding the signing key.
3. Create a public, non-prerelease GitHub Release tagged `v<VERSION>` in
   [spyroid/micro-dlna](https://github.com/spyroid/micro-dlna/releases).
   Attach the DMG and `appcast.xml`.

Sparkle reads `releases/latest/download/appcast.xml`; archive links point to the
specific release tag. The first published release activates the feed. The app
checks automatically and can install updates on quit.

Both archives and the feed are verified with Ed25519 signatures. The existing
private key is stored in macOS Keychain under account `local.microdlna`; keep a
secure backup. Never commit or upload it. When moving release builds to another
Mac, restore the same key rather than generating a replacement: installed copies
trust the public key embedded in `App/Info.plist`.

Do not edit `appcast.xml` after signing; regenerate it with Sparkle's tools.
Builds are ad-hoc signed without Apple notarization. Sparkle's license and the
project's [LICENSE](LICENSE) are bundled in the application.
