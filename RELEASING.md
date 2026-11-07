# Releasing

1. Pick the version, e.g. `0.2.0`. Update both places (they must match):
   - `Sources/MacDiskSleuthKit/Version.swift` → `MacDiskSleuthVersion.string`
   - `App/project.yml` → `MARKETING_VERSION` (and bump `CURRENT_PROJECT_VERSION`)
2. Check: `scripts/check-version.sh`
3. Merge to `main` once CI is green.
4. Tag and push: `git tag v0.2.0 && git push origin v0.2.0`

The **Release** workflow then runs the tests, builds a universal (arm64 + x86_64) CLI and app, and publishes a GitHub release with:

- `macdisksleuth-<version>-macos-universal.tar.gz`
- `MacDiskSleuth-<version>.zip`
- `SHA256SUMS`

Release notes are auto-generated from merged PRs. Tags with a suffix (`v0.2.0-rc1`) are marked pre-release. The workflow fails early if the tag doesn't match the source version.

## Signing and notarization

When the secrets below are set, the Release workflow signs the app and CLI with a Developer ID certificate, submits both to Apple's notary service, and staples the ticket to the app, so downloads open without Gatekeeper warnings. Without them it falls back to ad-hoc signing, and the release notes say so.

Add these under **Settings → Secrets and variables → Actions** on the repository:

| Secret | Value |
| --- | --- |
| `MACOS_CERTIFICATE_P12` | base64 of your **Developer ID Application** certificate exported as `.p12` |
| `MACOS_CERTIFICATE_PASSWORD` | the password you chose when exporting the `.p12` |
| `APPLE_TEAM_ID` | your 10-character Team ID |
| `ASC_KEY_ID` | App Store Connect API key ID |
| `ASC_ISSUER_ID` | App Store Connect issuer ID |
| `ASC_API_KEY_P8` | base64 of the `AuthKey_<KEY_ID>.p8` file |

How to get them:

1. **Certificate.** In Keychain Access, find `Developer ID Application: <name> (<TEAMID>)` under *My Certificates*, right-click → *Export*, choose `.p12`, and set a password. Then `base64 -i cert.p12 | pbcopy` and paste.
2. **API key.** In App Store Connect go to *Users and Access → Integrations → Team Keys*, generate a key with the *Developer* role, and download the `.p8` (it can be downloaded only once). Note the Key ID and the Issuer ID shown on that page. Then `base64 -i AuthKey_<KEY_ID>.p8 | pbcopy` and paste.

Never commit the `.p12` or `.p8`. Only the workflow's temporary keychain sees them, and it is deleted at the end of the job.
