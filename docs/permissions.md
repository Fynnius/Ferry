# Permissions

Ferry needs no special permissions — no Accessibility, no Full Disk Access, no Screen Recording. Depending on where your repositories live, macOS may ask a few ordinary questions. This page lists every prompt you can see and what it means.

## Gatekeeper: "Ferry Not Opened"

Downloads from the internet are quarantined. Ferry's release build is ad-hoc signed — not Developer ID signed and not notarized — so the first double-click shows **"Ferry" Not Opened** ("Apple could not verify "Ferry" is free of malware…") with only **Move to Trash** and **Done**. That is Gatekeeper, not a damaged download. Right-click → Open no longer overrides this on current macOS.

Apple's supported override:

1. Click **Done** (don't move it to the Trash).
2. Open **System Settings → Privacy & Security**.
3. Scroll down to **Security**. You'll see that "Ferry" was blocked.
4. Click **Open Anyway**, enter your password if asked, then click **Open** in the dialog that follows.

After that first exception Ferry opens normally. Details: [Apple — Safely open apps on your Mac](https://support.apple.com/en-us/102445).

Terminal alternative, if you prefer:

```bash
xattr -dr com.apple.quarantine /Applications/Ferry.app
open -a Ferry
```

Don't disable Gatekeeper or SIP system-wide for this.

## Folder access

| Prompt | When | What to choose |
| --- | --- | --- |
| "Ferry" would like to access files in your **Documents** / **Desktop** / **Downloads** folder | Ferry scans a folder inside one of these, or runs git in a repo there | **Allow** — otherwise repos in that folder stay invisible |
| "Ferry" would like to access files in **iCloud Drive** | A chosen folder is in iCloud Drive | **Allow**. Ferry never downloads files that are only in the cloud; repos that aren't downloaded are shown as such |
| "Ferry" would like to access files on a **removable** or **network volume** | A chosen folder is on an external or network drive | **Allow** |

Folders you pick in the open panel yourself usually need no extra prompt. If you clicked **Don't Allow**, change it under **System Settings → Privacy & Security → Files and Folders → Ferry**.

## Keychain

Your OpenAI API key (optional) is stored in the macOS Keychain, readable only while your Mac is unlocked and never synced. Because the release build is ad-hoc signed, macOS sees each update as a slightly different app, so after an update it may ask once:

> "Ferry" wants to use your confidential information stored in "io.github.fynnius.Ferry.openai" in your keychain.

Enter your login password and click **Always Allow**. If you'd rather not, remove the key in **Settings → AI** and paste it again.

## Git credentials

Ferry runs the git you already have, with your credential helper, SSH agent and signing setup. Two things can appear:

- **A sign-in dialog from Ferry** — git asked for HTTPS credentials your credential helper doesn't have. It only appears for something you started (push, pull, sync, fetch), one at a time; background fetches never ask. Ferry passes the answer straight to git and never stores it; your credential helper (usually the macOS Keychain) does. For GitHub it never asks for a password — GitHub doesn't accept them — but offers to connect the GitHub CLI or takes a token ([Signing in to GitHub](install.md#signing-in-to-github)).
- **Your SSH agent's or password manager's prompt** (e.g. 1Password) — that's your agent, as in Terminal.

SSH connections never prompt inside Ferry for a passphrase or host key. If a push fails with an authentication error, run `git push` once in Terminal (Ferry's **Open in Terminal**, ⌃⌘T) to accept the host key or unlock the key, then try again.

## Launch at login

Turning on **Settings → General → Open at login** adds Ferry under **System Settings → General → Login Items**, and macOS shows a notification saying so. Turn it off in either place.

## Resetting

To make macOS ask about folders again:

```bash
tccutil reset SystemPolicyDocumentsFolder io.github.fynnius.Ferry
tccutil reset SystemPolicyDesktopFolder io.github.fynnius.Ferry
tccutil reset SystemPolicyDownloadsFolder io.github.fynnius.Ferry
```
