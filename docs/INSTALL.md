# Installing Sweep

For anyone installing Sweep on a Mac. No developer tools needed.

## Before you start

- **macOS 14 (Sonoma) or later.** Apple menu → About This Mac shows your version.
- Apple Silicon or Intel — both work.

## 1. Download

Go to the [Releases page](https://github.com/Udhayveer101/Sweep/releases) and download
`Sweep-1.0.1.dmg`.

## 2. Install

1. Double-click the downloaded `Sweep-1.0.1.dmg`.
2. A window opens with the Sweep icon and an Applications folder.
3. Drag **Sweep** onto **Applications**.
4. Eject the disk image (click the ⏏ next to "Sweep" in the Finder sidebar).

## 3. First launch

Open Sweep from Applications the same way you would any other app. There is no warning to get
past and no workaround needed.

Sweep is signed with an Apple Developer ID certificate and has been notarized by Apple, which
means Apple has scanned the build and issued it a ticket. That ticket is stapled into both the
app and the disk image, so macOS can verify it even if you are offline the first time you open
it.

If you are upgrading from 1.0, that release was ad-hoc signed and did show a Gatekeeper warning.
Drag the old copy to the Trash first, then install this one; the warning is gone.

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
This should not happen with a release downloaded from the Releases page, since those builds are
notarized. If it does, the download is likely incomplete or corrupted — delete it and download
again. You can confirm the file is intact by comparing its checksum to the one in the release
notes:

```bash
shasum -a 256 ~/Downloads/Sweep-1.0.1.dmg
```

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
