# Deployment

## Local build

```bash
./make-app.sh release      # produces build/Sweep.app, ad-hoc signed
./make-dmg.sh              # produces build/Sweep-<version>.dmg and prints its SHA-256
```

## Signed release build

One command, once the two prerequisites below exist:

```bash
SWEEP_SIGN_ID="Developer ID Application: Your Name (TEAMID)" \
SWEEP_NOTARY_PROFILE=sweep-notary \
./make-release.sh
```

It builds, signs the app with Hardened Runtime and a secure timestamp, notarizes and staples it,
builds the DMG *from the stapled app*, notarizes and staples the DMG as well, then verifies the
result — including assessing a quarantined copy with `spctl`, which is the check that actually
predicts what a downloader sees. The script fails rather than reporting success if any of it
does not pass.

Both scripts read the identity from `SWEEP_SIGN_ID`; nothing about the signing account is
written into the repository. With the variable unset the build is ad-hoc, so a fresh clone still
produces a runnable app.

### Prerequisite 1 — the certificate

A **Developer ID Application** certificate and its private key in the login keychain. Confirm
with `security find-identity -v -p codesigning`; the identity string it prints is what
`SWEEP_SIGN_ID` should be set to. Note that an *Apple Development* certificate is not a
substitute — it cannot sign for distribution and notarization will reject it.

### Prerequisite 2 — notarization credentials

Stored once in the keychain, so no secret ever appears in a script, a shell history, or the
process table:

```bash
xcrun notarytool store-credentials "sweep-notary" --apple-id <id> --team-id <team>
# or, with an App Store Connect API key:
xcrun notarytool store-credentials "sweep-notary" --key <AuthKey.p8> --key-id <id> --issuer <uuid>
```

Keep any `.p8` key outside this repository.

### Why there is no entitlements file

Sweep needs no Hardened Runtime exceptions. It has no JIT, allocates no unsigned executable
memory, does no dyld interposing, and loads no third-party libraries. Its access to user files
is governed by TCC, which is not an entitlement — the sandbox file entitlements apply only to
sandboxed apps, and Sweep is not one. An entitlements plist would grant nothing and would have
to be read to establish that.

The bundle identifier is `com.sweep.app` and the signature is applied with a fixed identifier so
the identity stays stable between local rebuilds.

## Versioning

One source of truth: `CFBundleShortVersionString` (marketing) and `CFBundleVersion` (build) in
`Resources/Info.plist`. `make-dmg.sh` reads the marketing version out of the built bundle, so
the artifact name follows automatically — `Sweep-1.0.1.dmg`. The Git tag is `v` plus the same
marketing version (`v1.0.1` for the 1.0.1 release), and the GitHub release is named `Sweep 1.0.1`.
Bump the plist, rebuild, tag; nothing else carries a version number.

## Signing status

**Resolved at 1.0.1.** Releases are signed with `Developer ID Application: Udhayveer Singh
(P66SB4MX92)` and notarized by Apple. Both the app and the DMG carry stapled tickets, so they
validate offline.

Recorded because the difference is measurable rather than cosmetic. The same test, run on both
releases — quarantine attribute applied, then `spctl -a -t exec`:

| Release | Signature | Result |
|---|---|---|
| 1.0 | ad-hoc | `rejected` |
| 1.0.1 | Developer ID + notarized | `accepted`, `source=Notarized Developer ID` |

Notarization of the app took roughly 25 minutes in Apple's queue; the DMG took under a minute.
The queue is the whole cost, and it varies — budget for it rather than assuming the first
timing repeats.

Certificate expiry: **1 Feb 2027**. Builds already notarized keep validating past that date
because the signature carries a secure timestamp; signing *new* builds requires renewal.

### App Store distribution — not viable as designed, by choice
The App Sandbox would prevent Sweep from reading `~/Library/Caches` and `~/Library/Application
Support` for other applications, which is most of what it does. Direct distribution is the
correct channel for this product; this is a design conclusion, not a gap.

## Known operational note: ad-hoc rebuilds reset TCC grants

Each ad-hoc rebuild changes the code signature, so macOS treats the app as a new identity and
re-asks for folder permissions. This was observed during development and is expected there.
Developer ID–signed releases do not have this problem: the signature is stable across builds, so
permission grants survive an update. Anyone developing against an unsigned local build should
still expect the re-prompting.

## Known limitations

- Scans cover the home folder only. System-level caches are out of scope by design.
- A cleanup interrupted by a crash is recoverable from the Trash but is not written to the
  history log (see `docs/SECURITY.md`).
- Hardlinked files may cause the freed-space figure to overstate the real saving.
- Scheduled and background cleaning are not implemented. The research flagged this as
  experimental and trust-risky; it is deliberately omitted rather than half-built.

## Verification before release

```bash
swift test                                   # 83 tests across 13 suites
SWEEP_PERF=1 swift test --filter Performance # timings on the target machine
./make-app.sh release && ./make-dmg.sh
```

Then install the artifact the way a user would, rather than testing the development build:

```bash
hdiutil attach build/Sweep-1.0.1.dmg -nobrowse
cp -R /Volumes/Sweep/Sweep.app /Applications/
hdiutil detach /Volumes/Sweep
codesign --verify --deep --strict /Applications/Sweep.app
open /Applications/Sweep.app
```
