# Unsigned builds & releases (no developer account)

`.github/workflows/unsigned-release.yml` builds and publishes installable
binaries without any Apple Developer Program membership, Play Console account,
or repository secrets. Only the automatically provisioned `GITHUB_TOKEN` is
used.

## Outputs

| Job | Runner | Output |
| --- | --- | --- |
| `android` | `ubuntu-latest` | `SpotiFLAC-<version>-arm64.apk`, `-arm32.apk`, `-universal.apk` (when produced) |
| `ios` | `macos-15` | `SpotiFLAC-<version>-ios-unsigned.ipa` (a real `.ipa` — `Payload/Runner.app`, not a renamed zip) |
| `release` | `ubuntu-latest` | GitHub Release with all binaries plus `SHA256SUMS.txt` |

Both platform jobs run in parallel; each also uploads its binaries as workflow
artifacts (14-day retention) so you can grab a build without publishing.

## How it stays signing-free

- **Android** — `android/app/build.gradle.kts` falls back to the debug signing
  config when `key.properties` is absent, so the release APK is self-signed and
  installs directly on device. `apksigner verify` runs as a sanity gate.
- **iOS** — the Runner archive is built with `CODE_SIGNING_ALLOWED=NO`, then the
  `.app` is packaged into `Payload/` and zipped as `.ipa`. Any leftover
  `_CodeSignature` / `embedded.mobileprovision` is stripped so sideloaders
  (AltStore, SideStore, Sideloadly, TrollStore) re-sign a clean payload with the
  user's own Apple ID.

## Triggering a release

1. **Tag push** (recommended):
   ```bash
   git tag -a v4.9.0 -m "Release v4.9.0" && git push origin v4.9.0
   ```
   Tags matching `v*` start the workflow; `-alpha`/`-beta`/`-rc`/`-preview`
   suffixes are published as pre-releases automatically.
2. **Manual run**: *Actions → Unsigned Release → Run workflow*. Leave `version`
   empty to reuse the `pubspec.yaml` version, and untick `publish` to build
   artifacts only, without creating a release.

> `auto-tag.yml` pushes tags using the default `GITHUB_TOKEN`. GitHub does not
> re-trigger workflows for such pushes, so auto-tagged versions must be released
> via the manual run above (or by giving `auto-tag.yml` a PAT).

## Relationship to `release.yml`

`release.yml` is the upstream signed pipeline (keystore, AltStore source,
Telegram broadcast). Its tag trigger is disabled in this fork so the two
pipelines never race for the same release; it remains available via
*Run workflow* if you later configure the signing secrets.

## Versions pinned by the workflow

Flutter comes from `.fvmrc`, Go from `go_backend/go.mod`. The rest is declared
in the workflow `env:` block — Android NDK `29.0.14206865`, platform/build-tools
`37.0.0`, Xcode `26.1.1` — keep those aligned with `ci.yml` when bumping.
