# Installing Sweep

For anyone installing Sweep on a Mac. No developer tools needed.

## Before you start

- **macOS 14 (Sonoma) or later.** Apple menu → About This Mac shows your version.
- Apple Silicon or Intel — both work.

## 1. Download

Go to the [Releases page](https://github.com/Udhayveer101/Sweep/releases) and download
`Sweep-1.0.dmg`.

## 2. Install

1. Double-click the downloaded `Sweep-1.0.dmg`.
2. A window opens with the Sweep icon and an Applications folder.
3. Drag **Sweep** onto **Applications**.
4. Eject the disk image (click the ⏏ next to "Sweep" in the Finder sidebar).

## 3. First launch — important

Sweep is not yet signed with an Apple Developer ID certificate (see
[Why the warning appears](#why-the-warning-appears)). **macOS will refuse to open it on the
first try.** This is expected and is a one-time step.

You will see: *"Sweep" cannot be opened because Apple cannot check it for malicious software.*

To open it:

1. Open **System Settings → Privacy & Security**.
2. Scroll down to the Security section. There is a line saying *"Sweep" was blocked*.
3. Click **Open Anyway**, then confirm with Touch ID or your password.

If that line is not there, run this in Terminal instead, then open Sweep normally:

```bash
xattr -d com.apple.quarantine /Applications/Sweep.app
```

After this, Sweep opens by double-clicking like any other app.

### Why the warning appears

Apple's Gatekeeper only trusts apps signed with a paid Apple Developer ID certificate and
notarized by Apple. Sweep's author does not currently hold that certificate, so the release
build carries an *ad-hoc* signature. The app is unchanged and complete — macOS simply cannot
attribute it to a registered developer. This is verified behaviour, not a guess: a quarantined
copy of the release was tested and Gatekeeper rejected it.

## 4. Permissions

The first time Sweep scans, macOS may ask for access to your **Desktop**, **Documents**, and
**Downloads** folders. Sweep asks for these because it looks there for old installers, old
screenshots, and large files you have not opened in a long time. Click **Allow** — or don't;
Sweep still works and simply finds less.

### Full Disk Access is optional

Some caches and logs are hidden from apps unless you grant Full Disk Access. Sweep does not
require it and never nags for it. If a scan reports folders it could not read and you want
those included:

1. **System Settings → Privacy & Security → Full Disk Access**
2. Click **+**, choose **Sweep** from Applications, and switch it on.
3. Quit and reopen Sweep.

You can revoke it at any time in the same place.

## 5. Using it

1. Open Sweep. Click **Scan**.
2. Wait for the scan. You can cancel at any point.
3. Review the results. **Only items Sweep considers safe are pre-selected.** Anything it is
   unsure about, and anything you created yourself, is listed but never ticked for you.
4. Click any item to see exactly why Sweep flagged it.
5. Click **Clean**. Items go to the Trash, not straight to deletion.
6. If you change your mind, click **Put Back** — it restores everything from that cleanup.

The only exception is emptying the Trash itself, which is permanent by nature. Sweep says so
before doing it.

## Uninstalling Sweep

Drag `/Applications/Sweep.app` to the Trash. That is all — Sweep installs no helper tool, no
background agent, and no login item.

To also remove its cleanup history:

```bash
rm -rf ~/Library/Application\ Support/Sweep
```

If you granted permissions, remove them under **System Settings → Privacy & Security** in the
Files and Folders and Full Disk Access lists.

## Troubleshooting

**"Sweep is damaged and can't be opened"**
This is the quarantine flag, not real damage. Follow step 3 above.

**Scan finds far less than expected**
macOS is hiding folders from Sweep. Grant Full Disk Access (step 4) and scan again. Sweep
lists unreadable folders explicitly rather than pretending they were empty.

**macOS keeps re-asking for folder permissions after an update**
Each unsigned build has a different signature, so macOS treats it as a new app. This stops
once the app is signed with a stable Developer ID certificate.

**A cleanup reported skipped items**
Sweep lists each skipped item with the specific reason — usually the file was in use, changed
between the scan and the cleanup, or macOS denied access. Nothing was silently ignored.

**Freed space looks smaller than the estimate**
Items go to the Trash first, and the Trash still occupies disk space until it is emptied. The
number Sweep shows is what it verified is actually gone.
