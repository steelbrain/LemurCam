<p align="center">
  <img src="icon.png" width="128" height="128" alt="LemurCam icon">
</p>

# LemurCam

**Turn IP cameras into a Mac webcam.**

LemurCam turns RTSP and ONVIF IP cameras into a macOS virtual camera, with an
optional virtual microphone for camera audio.

**Website:** [lemur.cam](https://lemur.cam) ·
**[Download Latest Release](https://github.com/steelbrain/LemurCam/releases/latest)**

## Features

- Virtual camera output for macOS apps
- RTSP URLs and ONVIF discovery
- Optional microphone output for camera audio
- Demand-driven streaming — only active when an app or the preview is using the feed
- Native video pipeline for smoother output and lower CPU usage
- Universal app for Apple Silicon and Intel Macs

## Getting Started

1. **Move LemurCam to `/Applications`** before opening it — macOS does not allow
   system extensions to load when the app is outside of this folder.
2. **Enable the camera extension** when LemurCam asks.
3. **Optionally enable the audio driver** for LemurCam Microphone.
4. **Add a camera.**
5. **Allow Local Network access** when prompted — LemurCam needs this to discover
   and connect to cameras on your Wi-Fi network.

## Compatible Cameras

Popular compatible camera lines include:

- **TP-Link Tapo**
- **Reolink**
- **Hikvision** and **Dahua** series
- **Amcrest**
- **UniFi Protect** cameras

Microphone pass-through works when the camera provides audio in common IP-camera
formats, including AAC, G.711, and L16.

**Requires macOS 14.0 (Sonoma) or later.**

## Building From Source

LemurCam is an XcodeGen project. `project.yml` is the source of truth for the
Xcode project.

```bash
xcodegen generate
scripts/ci.sh
```

For a local run, use `scripts/dev-run.sh`; the app must launch from
`/Applications` for the system extension, helper, and audio driver to work
correctly. Forks that use a different Apple Developer account must update the
bundle identifiers, app group, signing team, entitlements, and helper signing
requirements together.

## Issues And Feedback

If you've found a bug or have a feature request, please
[open an issue](https://github.com/steelbrain/LemurCam/issues/new).

## Author

[Anees Iqbal](https://aneesiqbal.ai) ([@steelbrain](https://github.com/steelbrain))
