# ShengJi 1.7.0 Beta

**English** | [Chinese (Simplified)](BETA.zh-CN.md)

ShengJi 1.7.0 is an experimental prerelease intended for manual testing. It is not offered through the stable in-app update channel and does not replace the latest stable Release. Install it only if you are comfortable testing unfinished features and reporting problems.

## What to test

- Local Gemma-powered transcript proofreading and evidence-based summaries.
- Automatic model loading and reliable model unloading after success, failure, cancellation, timeout, or leaving the task.
- Streaming AI output, undo, synchronized subtitle exports, and numbered transcript previews.
- Experimental cursor dictation, global start/stop shortcuts, and floating status controls.

## Known issue: cursor dictation

**Cursor dictation is currently not working reliably and may experience substantial delays in both its preview and text insertion. Do not rely on it for time-sensitive or important input.** Escape and Command-Shift-S handling may also require further testing across target apps.

Regular microphone and file transcription are separate workflows and remain the recommended ways to create transcripts in this beta.

## Beta update behavior

- Stable ShengJi installations use GitHub's latest stable Release and will not automatically receive this prerelease.
- This beta does not have a separate automatic beta-update feed. Download later beta builds manually from GitHub Releases.
- Back up important transcripts before replacing an existing installation.

## Installation and security notice

Download the DMG attached to the `v1.7.0` prerelease, open it, and drag ShengJi to Applications. This build is ad-hoc signed and is not Developer ID signed or notarized by Apple. macOS may require **System Settings → Privacy & Security → Open Anyway** on first launch. Continue only if you trust this repository.

## Feedback

Report problems in [GitHub Issues](https://github.com/maddylaneeee/ShengJi/issues). Include the Mac model, macOS version, recognition engine, target app for cursor dictation, reproduction steps, and the exact error when possible.
