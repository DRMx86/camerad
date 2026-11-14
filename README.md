# Camera (iOS 16+)

A SwiftUI camera app modelled on the iOS 16 Camera app, with a configurable save location
(custom folder, including a USB drive on a Lightning-to-USB adapter) and automatic fallback
to the Photo Library.

## Features

- Modes: Photo, Portrait (on devices with depth support), Square, Video, Slo-mo
- Back/front camera, lens buttons (0.5x / 1x / 2x / telephoto where present), pinch to zoom
- Tap to focus, drag up/down to adjust exposure
- Flash (auto/on/off; torch in video), Live Photo, self-timer (3s/10s), grid
- HEIC or JPEG photos; orientation follows the device
- **Settings → Storage**: save to Photo Library or a custom folder
  - Folder is chosen with the system picker (Files), so folders on an attached USB drive work
  - The choice is stored as a security-scoped bookmark and survives relaunches
  - If the folder/drive is missing or unwritable at save time, the item goes to the Photo Library
    and a notice is shown. The top bar chip shows where the next shot will go.

## Build

The Xcode project is generated with [XcodeGen](https://github.com/yonaskolb/XcodeGen):

```bash
brew install xcodegen
xcodegen generate
open Camera.xcodeproj
```

Before shipping, change `PRODUCT_BUNDLE_IDENTIFIER` (and `bundleIdPrefix`) in `project.yml`, and
select your team in Xcode for on-device runs.

## GitHub Actions

`.github/workflows/ios-build.yml` runs on every push/PR:

1. Generates the project with XcodeGen
2. Compiles for the iOS Simulator (compile check)
3. Builds an unsigned Release device build and uploads `Camera-unsigned.ipa` as an artifact

The unsigned IPA can be re-signed and installed with a tool such as Sideloadly or AltStore using
your own Apple ID. For a properly signed build, add your certificate and provisioning profile as
repository secrets and replace the "unsigned" step with a signed `xcodebuild archive` /
`-exportArchive` step.

## Using a USB drive

1. Connect the drive with a Lightning to USB adapter (some drives need the powered
   Lightning to USB 3 Camera Adapter with a charger attached).
2. Format: APFS, exFAT, FAT32 or HFS+. NTFS is read-only on iOS and will be rejected.
3. Settings → Custom Folder → Choose Folder…, then pick or create a folder on the drive.
4. Set **Save To** to Custom Folder (this happens automatically after choosing a folder).

Live Photos saved to a folder are stored as a `.heic` + `.mov` pair (they only behave as a
Live Photo inside the Photo Library). Slo-mo clips are recorded at 120/240 fps; the Photos app
treats them as slo-mo when saved to the library.

## Not included

Panorama, Time-lapse, Cinematic video, Photographic Styles, filters, macro mode and the system
Portrait blur preview/lighting effects (the app saves depth + portrait matte so the Photos app can
edit depth after the fact).

## Notes

This project was written without access to Xcode, so it hasn't been compiled or run on a device.
The first GitHub Actions run is the compile check; if it reports errors, they should be small
and local. Camera behaviour (Portrait, Slo-mo, Live Photo, USB writes) needs testing on real hardware.
