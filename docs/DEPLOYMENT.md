# Deployment

## Local build

```bash
./make-app.sh release      # produces build/Sweep.app, ad-hoc signed
```

The bundle identifier is `com.sweep.app` and the signature is applied with a fixed identifier so
the identity stays stable between local rebuilds.

## What genuinely cannot be completed here

These are external dependencies, not unfinished work. Nothing in the codebase pretends they are
done.

### 1. Developer ID signing — blocked on an Apple Developer account
The app is currently **ad-hoc signed**. Distribution to any other Mac requires a Developer ID
Application certificate.

Exact action required: enrol in the Apple Developer Program, install the certificate, then

```bash
codesign --force --options runtime --timestamp \
  --sign "Developer ID Application: YOUR NAME (TEAMID)" build/Sweep.app
```

Add `--options runtime` (Hardened Runtime) as shown — notarization rejects builds without it.

### 2. Notarization — blocked on the same account
```bash
ditto -c -k --keepParent build/Sweep.app build/Sweep.zip
xcrun notarytool submit build/Sweep.zip --apple-id <id> --team-id <team> --password <app-specific> --wait
xcrun stapler staple build/Sweep.app
```

Until this is done, Gatekeeper will require a right-click → Open on first launch on another Mac.

### 3. App Store distribution — not viable as designed, by choice
The App Sandbox would prevent Sweep from reading `~/Library/Caches` and `~/Library/Application
Support` for other applications, which is most of what it does. Direct distribution is the
correct channel for this product; this is a design conclusion, not a gap.

## Known operational note: re-signing resets TCC grants

Each ad-hoc rebuild changes the code signature, so macOS treats the app as a new identity and
re-asks for folder permissions. This was observed during development and is expected. A stable
Developer ID signature makes grants persist across updates.

## Known limitations

- Scans cover the home folder only. System-level caches are out of scope by design.
- A cleanup interrupted by a crash is recoverable from the Trash but is not written to the
  history log (see `docs/SECURITY.md`).
- Hardlinked files may cause the freed-space figure to overstate the real saving.
- Scheduled and background cleaning are not implemented. The research flagged this as
  experimental and trust-risky; it is deliberately omitted rather than half-built.

## Verification before release

```bash
swift test                                   # 57 tests
SWEEP_PERF=1 swift test --filter Performance # timings on the target machine
./make-app.sh release && open build/Sweep.app
```
