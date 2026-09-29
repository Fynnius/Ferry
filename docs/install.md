# Installing Ferry

## Before you start

- A Mac with **macOS 26 or later** (Apple silicon or Intel).
- **git 2.25 or later.** If you've never used git in Terminal, install Apple's Command Line Tools first:

  ```bash
  xcode-select --install
  ```

  Homebrew's git (`brew install git`) works too. Ferry uses whichever git your shell finds, and tells you on launch if it can't find one.

## Download

1. Open the [latest release](https://github.com/Fynnius/Ferry/releases/latest) and download `Ferry-<version>-macOS.zip`.
2. Optional — check the download against the SHA-256 in the release notes:

   ```bash
   shasum -a 256 ~/Downloads/Ferry-*-macOS.zip
   ```

3. Double-click the zip to unzip it, then drag **Ferry.app** into **Applications**.
4. Double-click Ferry. macOS shows **"Ferry" Not Opened** — click **Done**.
5. Open **System Settings → Privacy & Security**, scroll to **Security**, click **Open Anyway** next to "Ferry was blocked", enter your password if asked, then click **Open**.

   This is needed once because Ferry isn't notarized by Apple. More, including a Terminal alternative: [permissions.md](permissions.md#gatekeeper-ferry-not-opened).

## First run

1. **Choose your folders.** Ferry suggests the usual places (`~/Developer`, `~/Projects`, `~/GitHub`, …) it finds on your Mac; add or remove folders until the list matches where you clone code. Ferry only reads — nothing changes until you commit.
2. **Watch the scan.** Repos appear as they're found. If macOS asks about your Documents, Desktop or iCloud Drive folder, click **Allow** (why: [permissions.md](permissions.md#folder-access)).
3. **Check the projects.** Ferry groups related repos into projects. Right-click a project to rename it, or use a repo's **…** menu to move or hide it — now or any time later.
4. **Optional extras.** Paste an OpenAI API key for ✨ commit messages, and choose whether Ferry shows in the menu bar. Both can be changed later in **Settings**.

That's it: repos that need you are at the top. Type a message, press **⌘↩**, then **Sync**.

## Updating

Download the new zip and replace `/Applications/Ferry.app` (quit Ferry first). Your folders, projects and settings are kept. macOS may ask once more about folder access and your Keychain — see [permissions.md](permissions.md#keychain).

## Uninstalling

1. Quit Ferry and move `/Applications/Ferry.app` to the Trash.
2. Remove its data and settings:

   ```bash
   rm -rf ~/Library/Application\ Support/Ferry
   defaults delete io.github.fynnius.Ferry
   ```

3. If you saved an OpenAI key, remove it in **Settings → AI** before step 1, or delete the "io.github.fynnius.Ferry.openai" item in Keychain Access.

## Build from source

Needs Xcode 27 or later.

```bash
git clone https://github.com/Fynnius/Ferry.git
cd Ferry
scripts/test.sh                      # engine + app tests
scripts/build-release.sh --install   # universal Release build, copied to /Applications
```

`build-release.sh` signs with the first *Apple Development* identity in your keychain if you have one (so macOS keeps folder permissions and Keychain access across rebuilds), otherwise ad-hoc. Build output goes to `~/Library/Caches/FerryBuild`.
