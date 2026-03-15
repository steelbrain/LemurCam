<p align="center">
  <img src="icon.png" width="128" height="128" alt="LemurCam icon">
</p>

# LemurCam

**Ditch the cable. Keep the camera.**

LemurCam is a macOS app that turns any IP camera into a virtual webcam. Use your RTSP or ONVIF cameras directly in Zoom, Teams, OBS, and any other app that supports camera input.

**Website:** [lemur.cam](https://lemur.cam) · **[Download Latest Release](https://github.com/steelbrain/LemurCam/releases/latest)**

## Features

- Virtual camera device that works with any macOS app
- ONVIF camera auto-discovery on your local network
- Direct RTSP stream support
- Demand-driven streaming — only active when an app is using the camera
- Menu bar app with quick-access popover
- Siri Shortcuts integration

## Getting Started

1. **Move LemurCam to `/Applications`** before opening it — macOS does not allow system extensions to load when the app is outside of this folder.
2. **Allow Local Network access** when prompted — LemurCam needs this to discover and connect to cameras on your Wi-Fi network.

## Compatible Cameras

LemurCam works with any IP camera that supports RTSP or ONVIF. Some popular options:

- **TP-Link Tapo** (C100, C200, C210) — great starter cameras at $20–35
- **Reolink** (E1, RLC-510A, RLC-810A)
- **Hikvision** and **Dahua** series
- **Amcrest** (IP2M, IP5M)
- **UniFi Protect** cameras

If your camera has an RTSP URL or supports ONVIF discovery, it will work with LemurCam.

**Requires macOS 14.0 (Sonoma) or later.**

## Issue Tracker

This repository serves as the public issue tracker for LemurCam. If you've found a bug or have a feature request, please [open an issue](https://github.com/steelbrain/LemurCam/issues/new).

## Technologies Used

LemurCam builds on several open-source projects, all licensed under the MIT License:

- **[XMLKit](https://github.com/steelbrain/XMLKit)** — XML parsing and composition, a Swift port of [xmltree-rs](https://github.com/eminence/xmltree-rs)
- **[IPCamKit](https://github.com/steelbrain/IPCamKit)** — RTSP packet depacketization, a Swift port of [Retina](https://github.com/scottlamb/retina)
- LemurCam itself has roots in **[UniCamEx](https://github.com/creativeIKEP/UniCamEx)**, an Unreal Engine streaming to Virtual Camera demo

## Author

[Anees Iqbal](https://aneesiqbal.ai) ([@steelbrain](https://github.com/steelbrain))
