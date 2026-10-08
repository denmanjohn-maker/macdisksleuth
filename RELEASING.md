# Releasing

1. Pick the version, e.g. `0.2.0`. Update both places (they must match):
   - `Sources/DiskSleuthKit/Version.swift` → `DiskSleuthVersion.string`
   - `App/project.yml` → `MARKETING_VERSION` (and bump `CURRENT_PROJECT_VERSION`)
2. Check: `scripts/check-version.sh`
3. Merge to `main` once CI is green.
4. Tag and push: `git tag v0.2.0 && git push origin v0.2.0`

The **Release** workflow then runs the tests, builds a universal (arm64 + x86_64) CLI and app, and publishes a GitHub release with:

- `disksleuth-<version>-macos-universal.tar.gz`
- `DiskSleuth-<version>.zip`
- `SHA256SUMS`

Release notes are auto-generated from merged PRs. Tags with a suffix (`v0.2.0-rc1`) are marked pre-release. The workflow fails early if the tag doesn't match the source version.

Binaries are ad-hoc signed, not notarized. Notarization needs an Apple Developer ID and secrets; add it to the workflow when you have one.
