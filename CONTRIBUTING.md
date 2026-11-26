# Contributing to LocalScribe

Thank you for helping improve LocalScribe. Bug reports, reproducible test cases, documentation fixes, translations, and focused pull requests are welcome.

## Before opening an issue

- Search existing issues first.
- For bugs, include the LocalScribe version, macOS version, Mac model, selected recognition engine and model, clear reproduction steps, and the expected and actual behavior.
- Remove private audio, transcripts, file paths, names, and other sensitive information from logs and screenshots.
- For feature proposals, explain the user problem and workflow before suggesting a particular implementation.

## Development setup

LocalScribe requires an Apple silicon Mac, Xcode with the macOS 26 SDK or newer, and its Command Line Tools. CI builds, tests, and analyzes on macOS 26 Apple silicon. The app deployment target remains macOS 15.5; running Apple Speech and Apple Intelligence features requires macOS 26 or later and their respective system resources.

The generated Xcode project is committed, so you can build it directly:

```sh
xcodebuild \
  -project LocalScribe.xcodeproj \
  -scheme LocalScribe \
  -destination 'platform=macOS,arch=arm64' \
  build
```

Run the tests before submitting a pull request:

```sh
xcodebuild \
  -project LocalScribe.xcodeproj \
  -scheme LocalScribe \
  -destination 'platform=macOS,arch=arm64' \
  test
```

Keep permanent tests focused on consequential regressions and subtle contracts that are easy to overlook. See the [test selection criteria](LocalScribeTests/README.md). Run model experiments and performance investigations as needed for the relevant change.

## Regenerate the project

When changing file membership, resources, frameworks, or build settings, regenerate the committed project with Ruby and the `xcodeproj` gem. Install the gem for the Ruby interpreter you use to run the generator:

```sh
gem install --user-install xcodeproj
ruby generate_project.rb
```

Review the generated `LocalScribe.xcodeproj` diff before committing. Documentation-only changes do not require project regeneration.

## Packaging and releases

`./tools/package_local_release.sh` builds and validates ZIP and DMG packages. Set `CODESIGN_IDENTITY=-` for an ad-hoc build. Public packages are not Developer ID signed or notarized by Apple.

After release validation, pushing a tag matching `CFBundleShortVersionString` in `LocalScribe/Resources/Info.plist` (for example, `v1.9.0`) publishes a GitHub Release through `.github/workflows/release-unsigned.yml`. Verify the matching DMG, ZIP, checksums, and `update.json` assets before announcing the release.

Keep the current version's `RELEASE_NOTES_<version>.md` at the repository root for packaging. When preparing the next release, move the previous file into the [release notes archive](Documentation/ReleaseNotes/README.md), fix its relative links, and update the archive index.

## Pull requests

- Keep each pull request focused on one problem.
- Describe the user-visible behavior and how it was tested.
- Add or update tests for distinct data-loss, privacy, lifecycle, or compatibility risks; avoid duplicating routine implementation checks.
- Update English, Simplified Chinese, and Japanese strings together for user-facing changes. Keep the three READMEs consistent and link localized guides explicitly.
- Do not commit downloaded recognition models, private test media, credentials, signing identities, or notarization secrets.
- Preserve third-party license notices and do not relicense vendored components or models.

Large architectural changes are easier to review when discussed in an issue first.

## License

By contributing source code or documentation, you agree that your contribution may be distributed under the repository's MIT License. Third-party components and models retain their original licenses.

