# Install ShengJi 1.6.7 on your Mac

**English** | [Chinese (Simplified)](INSTALL.zh-CN.md) · [Project overview](README.md)

You do not need Xcode, Terminal, or programming knowledge. Use an Apple silicon Mac running macOS 15.5 or later. Choose Apple menu → About This Mac to check. Apple recognition and floating live captions require macOS 26 or later.

## Why macOS may block the first launch

The public download has an **ad-hoc signature**: it checks the integrity of the packaged code, but does not establish an Apple-verified developer identity. It is **not Developer ID signed and has not been notarized by Apple**. A signature or matching download checksum does not mean Apple has reviewed the app for malware. Approve an exception only if you trust this project and the download source. [Apple explains these checks](https://support.apple.com/en-us/102445).

## 1. Download and copy the app

1. Visit the [official GitHub Release](https://github.com/maddylaneeee/ShengJi/releases/latest). Download `LocalScribe-macOS-arm64.dmg` from its **Assets** list. Do not download the source-code ZIP to install the app.
2. Open the downloaded DMG from Finder → Downloads.
3. Drag the app icon to **Applications** in the disk-image window. Wait for the copy to finish. The bundle is named `LocalScribe.app`; Finder or the security alert may show the localized app name.
4. Eject the disk image in Finder. Open **Applications** and use the copied app for the remaining steps.

## 2. Try opening it once

Double-click the installed app. If macOS says it cannot verify the developer or cannot check the app for malicious software, dismiss the alert with **Done**, **Cancel**, or the equivalent button that keeps the app. This attempt is needed before its exception appears in System Settings. If the app opens normally, continue to step 4.

## 3. Approve this app in System Settings

On **macOS 26 and macOS 27**, open Apple menu → **System Settings → Privacy & Security**, then scroll to **Security**. Find the warning naming this app. If **Open** is shown, click it, then choose **Open Anyway**; some versions show **Open Anyway** directly. Review the app name and provide your Mac login password or confirm **Open / OK** when prompted. You are approving this installed app. [Apple’s macOS 26 instructions](https://support.apple.com/guide/mac-help/mh40616/26/mac/26) and [macOS 27 instructions](https://support.apple.com/guide/mac-help/mh40616/27/mac/27) describe this route.

After approval, the installed copy normally opens by double-clicking it. A replacement or update may require approval again.

## 4. Allow the permissions you need

When you start microphone transcription, allow **Microphone** access. When capturing Mac audio, allow the requested **Screen & System Audio Recording** permission. Follow a restart prompt if macOS displays one. File transcription uses files you choose. If you declined a permission, revisit its category in System Settings → Privacy & Security.

On macOS 26 or later, use the default Apple recognition option. On macOS 15.5–25, choose a third-party model on the home screen and finish downloading it before transcription. See the [download and usage guide](Documentation/DOWNLOAD.md) for recognition choices and optional SHA-256 verification.

## If installation is blocked

- **No Open Anyway button:** first attempt to open the copy in Applications again, then return to Privacy & Security and scroll down. Apple says the button is available for about an hour after the attempt. Check that the warning names the copy you installed. A managed work or school Mac may require its administrator’s help.
- **“Damaged” or “will damage your computer”:** stop and do not approve an exception. Remove that download, obtain a fresh copy from the official Release, and report the exact message if it repeats. These alerts differ from an unidentified-developer warning. [Apple’s explanation](https://support.apple.com/en-us/102445) covers the distinction.
- **The app stays inside the disk image:** copy it to Applications, eject the image, and open the installed copy.
- **Still unable to open:** [report an issue](https://github.com/maddylaneeee/ShengJi/issues) with the macOS version, Mac chip, app version, and exact alert text. Do not include private recordings or transcripts.

These steps use macOS’s per-app approval interface. Do not disable Gatekeeper or run commands that remove download quarantine to complete this installation.
