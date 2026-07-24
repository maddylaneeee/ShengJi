# Contributing to ShengJi

Thank you for helping improve ShengJi. Bug reports, reproducible test cases, documentation fixes, translations, and focused pull requests are welcome.

## Before opening an issue

- Search existing issues first.
- For bugs, include the ShengJi version, macOS version, Mac model, selected recognition engine and model, clear reproduction steps, and the expected and actual behavior.
- Remove private audio, transcripts, file paths, names, and other sensitive information from logs and screenshots.
- For feature proposals, explain the user problem and workflow before suggesting a particular implementation.

## Development setup

ShengJi requires an Apple silicon Mac with Xcode and its Command Line Tools.

```sh
ruby generate_project.rb

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

## Pull requests

- Keep each pull request focused on one problem.
- Describe the user-visible behavior and how it was tested.
- Add or update tests when behavior changes.
- Update English and Simplified Chinese strings together for user-facing changes.
- Do not commit downloaded recognition models, private test media, credentials, signing identities, or notarization secrets.
- Preserve third-party license notices and do not relicense vendored components or models.

Large architectural changes are easier to review when discussed in an issue first.

## License

By contributing source code or documentation, you agree that your contribution may be distributed under the repository's MIT License. Third-party components and models retain their original licenses.

