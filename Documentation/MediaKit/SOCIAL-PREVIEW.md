# GitHub Social Preview

[Preview image](social-preview-en.jpg)

## Export

- English JPEG, 1280 × 640 pixels (2:1), 214,539 bytes.
- Intended for the repository's Settings → Social preview upload.
- Uses the built-in ImageGen tool with the existing [English home screenshot](../Screenshots/home-en.png) and [app icon](../../LocalScribe/Resources/Assets.xcassets/AppIcon.appiconset/icon_512.png) as image references, followed by resizing and JPEG encoding for delivery.
- The depicted interface is based on an earlier app capture, not a fresh screenshot of version 1.9.0. This AI-assisted composition should not be used as exact UI documentation.
- Apple Intelligence is qualified with “On supported Macs”; full system and availability requirements remain in the project README.

## Publication

The image file and the live GitHub Social preview setting are separate. After owner review and merge, upload this JPEG in repository settings. Committing the file alone does not change the active preview. Preserve the previous setting until the new image is approved.

## Generation prompt

```text
Use case: compositing / ads-marketing.
Create one premium GitHub repository social preview for LocalScribe, using the supplied REAL macOS app screenshot and actual app icon.
Input image 1: supporting insert, the real LocalScribe English home screenshot. Preserve its interface, text, layout, proportions, macOS window chrome and authenticity; place it as an actual screenshot panel, NOT a newly invented UI. Input image 2: actual LocalScribe app icon, preserve the blue-violet rounded-square and black waveform/microphone identity.
Output: a wide 2:1 horizontal social card, target 1280 x 640 pixels, opaque background, carefully composed for thumbnail readability.
Art direction: luminous pearl-white / very pale ice-blue editorial product poster. Deep ink-navy typography, clear cobalt accents, a sculptural translucent electric-blue sound ribbon curving behind the right-hand screenshot, subtle fine grain and soft studio light. Modern native Mac product, calm, precise, beautifully typeset, no clutter. This must feel like finished designer artwork, not a template or dashboard.
Layout: generous 52-pixel safe margins. Left approximately 45% for branding and message, right approximately 55% for the REAL screenshot as one large nearly front-facing floating window with a restrained soft shadow. Keep the screenshot unobscured and sharply legible. Do not put it in a laptop or phone. Brand icon small near upper left beside LocalScribe wordmark. Main heading large, dark and readable, two lines. Clear subordinate capability line below. At lower left, an Apple Intelligence line with a small availability qualifier. No CTA buttons, no pills, no additional icons, no URL, no version number.
Only this poster copy, verbatim in English:
"LocalScribe"
"Your audio."
"Clearly written."
"Transcribe · Translate · Create subtitles"
"On-device Apple Intelligence*"
"*On supported Macs"
The supporting capability line may wrap naturally but cannot run into the screenshot. Ensure correct spelling and crisp typography. Do not introduce Apple logos or affiliation/endorsement marks. Do not generate fake transcript text or fake app controls. All interface content comes from the supplied screenshot. Use real screenshot geometry. No additional marketing claims, no watermark.
```
