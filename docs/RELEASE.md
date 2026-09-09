# Building and releasing DevWatch

Run the following commands from the repository directory. Building requires macOS and a Swift 6 toolchain.

## Build a Mac app

```sh
bash scripts/build-app.sh            # Build the app bundle at build/DevWatch.app
bash scripts/build-app.sh install    # Also copy it to /Applications and launch it
open build/DevWatch.app
```

The script creates a release app bundle as a universal binary for Apple Silicon and Intel (`--arch arm64 --arch x86_64`). It signs the app using the first “Developer ID Application” identity in the keychain, falling back to ad hoc signing. A consistent signing identity matters because macOS associates folder permissions with it. The app runs outside the App Sandbox so it can launch local development tools.

## Build an installable DMG

```sh
bash scripts/build-app.sh release
```

This creates `build/DevWatch.dmg` containing the app bundle and a shortcut to `/Applications` for drag-and-drop installation. The workflow signs with Developer ID and Hardened Runtime, submits the app and then the packaged DMG to Apple for notarization, and staples both tickets. Stapled tickets allow macOS to verify notarization without an internet connection.

Configure your local release settings in `scripts/release.env`. This file is intentionally excluded from version control because its settings are specific to each machine:

```sh
cp scripts/release.env.example scripts/release.env
```

| Setting | Description |
| --- | --- |
| `NOTARY_PROFILE` | Name of the `notarytool` keychain profile. Create it once with `xcrun notarytool store-credentials <name> --apple-id <email> --team-id <TEAMID>`; the command prompts for an app-specific Apple password. If this setting is missing, the release workflow stops with an explanation rather than guessing a profile. |
| `SIGN_IDENTITY` | Signing identity to use, such as `Developer ID Application: … (TEAMID)`. If omitted, the first matching identity in the keychain is used. List identities with `security find-identity -v -p codesigning`. |
| `SKIP_NOTARIZE=1` | Sign and build the DMG without Apple notarization. Intended for quick local runs; the result is not suitable for distribution. |

Each setting can also be supplied as an environment variable, which takes precedence over the file: `SKIP_NOTARIZE=1 ./scripts/build-app.sh release`. Use `DEVWATCH_RELEASE_ENV` to select a different configuration file. The file is parsed, not executed; unknown keys are skipped with a warning.

## Publish a GitHub release

```sh
bash scripts/build-app.sh publish
```

This uses the existing DMG, creates the tag `v<Version>`, pushes it to `origin`, and creates a GitHub release with the DMG attached. The asset name includes the version, and release notes are generated from commits since the previous tag.

The publish step deliberately does not rebuild the app, which would discard the notarized and stapled bundle. It stops if the DMG is missing or lacks a valid notarization ticket, the working tree is not clean, `HEAD` has not been pushed, or the tag already exists. For a new version, update the version number in `Support/Info.plist`, then run `release` followed by `publish`.

[Back to the README](../README.md)
