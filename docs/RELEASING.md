# Releasing Lowtide

A release is a signed, notarized build attached to a GitHub release. Every installed copy of
Lowtide checks the latest release once a day and offers to install it.

## What a release needs (once)

### From Apple

Notarized apps need a paid [Apple Developer Program](https://developer.apple.com/programs/)
membership (USD 99 a year). With it:

1. **Developer ID Application certificate.** In Xcode › Settings › Accounts › Manage
   Certificates, add a *Developer ID Application* certificate. Export it from Keychain Access
   (with its private key) as a `.p12` file with a strong password.
2. **App Store Connect API key for notarization.** In
   [App Store Connect › Users and Access › Integrations › Team Keys](https://appstoreconnect.apple.com/access/integrations/api),
   create a key with the *Developer* role. Download the `.p8` file (you only get one chance), and
   note its **Key ID** and the **Issuer ID** shown above the list.

The updater only installs a download signed by the same team as the running copy. Keep using
the same Apple Developer team, or the people already running Lowtide will have to download the
next version by hand.

### On GitHub

1. Settings › Environments › **New environment** named `release`. Under *Deployment branches and
   tags*, allow only tags matching `v*.*.*`, and add yourself as a required reviewer if you want
   to approve each release.
2. In that environment, add these secrets:

   | Secret | Value |
   |---|---|
   | `DEVELOPER_ID_P12` | `base64 -i DeveloperID.p12 \| pbcopy`, pasted |
   | `DEVELOPER_ID_P12_PASSWORD` | the `.p12` export password |
   | `NOTARY_KEY_P8` | `base64 -i AuthKey_XXXXXXXXXX.p8 \| pbcopy`, pasted |
   | `NOTARY_KEY_ID` | the API key's Key ID |
   | `NOTARY_ISSUER_ID` | the Issuer ID |

3. Settings › Actions › General: allow GitHub Actions, and give workflows *Read and write
   permissions* (the release job creates the release).
4. Settings › Code security: turn on *Private vulnerability reporting*, *Dependabot alerts* and
   *Secret scanning* with *Push protection*.

Delete the `.p12` and `.p8` files from your Downloads once they're stored. Never commit them:
`.gitignore` refuses `*.p12`, `*.p8`, `*.cer` and `*.mobileprovision`.

## Cutting a release

1. Move the `## [Unreleased]` notes in [CHANGELOG.md](../CHANGELOG.md) under a new heading,
   `## [1.2.0] - 2026-12-01`. That section becomes the release notes on GitHub.
2. Commit it to `main`, then tag and push:

   ```sh
   git tag v1.2.0
   git push origin main v1.2.0
   ```

3. The [Release workflow](../.github/workflows/release.yml) runs the tests, builds the app with
   both helpers, signs it, has Apple notarize the app and the disk image, and publishes
   `Lowtide-1.2.0.dmg`, `Lowtide-1.2.0.zip` and `SHA256SUMS` as the release. The version in
   the app comes from the tag; the build number is the workflow's run number.

Installed copies see the release within a day, or at once with Lowtide › Check for Updates….

A failed release leaves nothing published: fix the problem, delete the tag
(`git push --delete origin v1.2.0 && git tag -d v1.2.0`) and tag again. To re-run a release for
an existing tag, run the workflow by hand (Actions › Release › Run workflow) with the tag.

## Releasing from your own Mac

`scripts/release.sh` does the same build locally, using the Developer ID certificate in your
keychain and a notarytool profile:

```sh
xcrun notarytool store-credentials lowtide --key AuthKey_XXXXXXXXXX.p8 --key-id <Key ID> --issuer <Issuer ID>
LOWTIDE_NOTARY_PROFILE=lowtide scripts/release.sh
```

It leaves the app, the DMG, the zip and `SHA256SUMS` in `dist/`. Upload them with
`gh release create v1.2.0 dist/Lowtide-1.2.0.dmg dist/Lowtide-1.2.0.zip dist/SHA256SUMS`.

## How updates reach people

`Support/Info.plist`'s `LowtideUpdateFeed` points at this repository's latest release in
GitHub's API. Once a day (and from Check for Updates…) Lowtide reads it and compares its version
with its own. When a newer release has `Lowtide-<version>.zip`, Lowtide offers it; installing
downloads the zip, checks that the app inside is signed by the same team and accepted by
Gatekeeper, moves the old copy to the Trash, puts the new one in its place and relaunches.
Drafts and pre-releases are never offered. A copy that isn't a signed release (built from
source) opens the release's download instead.
