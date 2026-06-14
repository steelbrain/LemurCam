# LemurCam Agent Guide

This guide is for agents and contributors working in this repository. Follow it
when changing the app, camera extension, audio driver, helper, tests, scripts, or
website.

## Project Overview

LemurCam is a macOS virtual webcam app. It takes RTSP or ONVIF IP camera feeds,
decodes them in the main app, and writes frames into a Core Media I/O camera
system extension. Other macOS apps see the extension as a virtual camera named
`LemurCam`.

The app also includes an optional virtual microphone. Camera audio is decoded by
the app, converted to the microphone format, written to shared memory, and
consumed by a Core Audio HAL driver installed by a privileged helper.

Minimum deployment is macOS 14.0. The project is generated with XcodeGen from
`project.yml`; treat `project.yml` as the source of truth for targets and build
settings. Do not hand-edit `LemurCam.xcodeproj`.

## Repository Layout

- `App/`: SwiftUI menu bar app. It manages camera sources, settings, previews,
  logs, extension activation, setup, and demand-driven streaming.
- `Extension/`: CMIOExtension system extension. It exposes the source stream
  visible to macOS and a sink stream that the app writes into.
- `Audio/`: Core Audio AudioServerPlugIn driver for the virtual microphone.
- `Helper/`: Privileged SMAppService daemon that installs/removes the audio
  driver and restarts `coreaudiod`.
- `Shared/`: Shared configuration, IPC constants, audio shared-memory types,
  placeholder rendering, tuning, and logging helpers.
- `Tests/`: XCTest coverage for source storage, Keychain behavior, ONVIF,
  RTSP processing, audio decoding/ring behavior, setup decisions, extension
  state, logging, configuration, and boot sanity checks.
- `website/`: Public landing site for `lemur.cam`; a self-contained Next.js app.
- `scripts/`: Local development, CI, cleanup, and fake-camera helpers.

## Required Validation

Before implementing anything, gather context from the current tree:

- Read the files you plan to modify and their direct callers/consumers.
- Search for existing patterns before adding new abstractions.
- Confirm type names, settings keys, bundle identifiers, entitlements, and
  function signatures against the actual code.
- For conventions you are unsure about, find at least two existing examples.

Do not build from memory. This repository has sensitive platform boundaries:
system extensions, app groups, Keychain, XPC, a root helper, HAL plug-ins, and
cross-process shared memory.

For non-trivial work, split the task into small reviewable chunks. After each
chunk, review the diff for behavior, edge cases, style, and tests before moving
on.

## Build And Test

Core commands:

```bash
xcodegen generate       # Regenerate LemurCam.xcodeproj from project.yml
swiftlint lint --strict # Lint only; warnings are errors
scripts/ci.sh           # Full local CI: SwiftLint, build, tests
scripts/dev-run.sh      # Build Debug, install to /Applications, launch
scripts/dev-camera.sh   # Fake RTSP + ONVIF camera for testing without hardware
scripts/dev-clean.sh    # Dry-run cleanup for local extension/app state
```

Website commands run from `website/`:

```bash
npm install
npm run dev
npm run build
npm run lint
```

`scripts/ci.sh` runs SwiftLint, generates the Xcode project, builds the app
targets, and runs tests. Do not weaken SwiftLint or build settings to make a
change pass; fix the code.

The GitHub workflow runs SwiftLint and `xcodebuild test` on macOS with code
signing disabled for CI. Local app runs and distribution builds require proper
Apple signing configuration.

## Running Locally

The app refuses to launch from anywhere but `/Applications`. Xcode's Run button
normally launches from DerivedData, which trips that guard. Use
`scripts/dev-run.sh` for a normal local run.

To debug:

1. Run `scripts/dev-run.sh`.
2. In Xcode, use Debug > Attach to Process.

`scripts/dev-camera.sh` starts a local RTSP stream plus a small ONVIF responder.
It is the preferred way to exercise RTSP, ONVIF discovery, and microphone audio
without physical camera hardware.

`scripts/dev-clean.sh` is intentionally powerful. It defaults to dry-run mode,
but `--execute` can stop LemurCam processes, delete app bundles, remove the HAL
driver, reset camera privacy state, delete app/user state, delete Keychain items
for LemurCam, and touch system-extension state. Read its output before running
with `--execute`.

## Signing And Identifiers

Official LemurCam builds use the `cam.lemur.app` bundle identifier family and
the configured Apple team ID in `project.yml` and shared signing requirements.
These values are part of the app group, XPC validation, helper validation, and
system-extension identity.

If you are building a fork with a different Apple Developer account, expect to
update all related identifiers together:

- `DEVELOPMENT_TEAM` in `project.yml`
- app, extension, helper, test, and audio bundle identifiers in `project.yml`
- app group and team-qualified identifiers in `Shared/LemurCamConfig.swift`
- helper, app, and driver code-signing requirements in
  `Shared/LemurAudioHelper.swift`
- entitlements and LaunchDaemon identifiers when changing the bundle ID family

Changing only one of these usually produces an install, XPC, app-group, or
system-extension failure.

## Architecture Rules

`SetupCoordinator` is the app-lifetime `@Observable` owner of install state for
both the camera system extension and the audio helper/driver. The setup window,
settings sidebar, and popover read this state from the coordinator. Do not
re-infer install state independently in views.

Camera-extension state is ground truth, not inference. `CameraExtensionController`
derives it from `OSSystemExtensionRequest.propertiesRequest`
(`isEnabled`, `isAwaitingUserApproval`, `isUninstalling`) plus
`CoreMediaIOUtil.isLemurCameraLive`. `AppDelegate` refreshes when the app becomes
active because approval happens out of process in System Settings.

`SetupView` is a guided setup window for the camera and optional microphone
approval gates. `SettingsView` is a `NavigationSplitView` sidebar, not a `TabView`.

The Preview settings tab and the menu bar popover intentionally create preview
demand. Closing both should drop preview demand so streams can pause when no
external app is using the camera.

Resolution and frame-rate choices are stored in the app group and require an app
restart to apply to the extension stream format.

## Streaming And Demand

The app supports direct RTSP URLs and ONVIF cameras. ONVIF discovery uses
WS-Discovery UDP probing. Stream decoding uses `IPCamKit`, VideoToolbox, and a
jitter buffer before frames are converted to sample buffers for the extension.

Demand matters. The RTSP pipeline should run only when there is an external
camera consumer or when in-app preview is enabled. Avoid background work that
keeps cameras connected with no consumer.

Camera audio is decoded in `App/RTSP/AudioDecoder.swift`:

- G.711 mu-law/a-law and L16 are decoded directly.
- AAC is decoded via an AudioToolbox `AudioConverter`.
- Output is converted to 48 kHz Float32 stereo with `AVAudioConverter`.
- Audio production is owned by `StreamCoordinator` and demand-gated by driver
  `audioConsumerStarted` / `audioConsumerStopped` notifications.

Toggling microphone demand must not reconnect a live video stream.

## Extension And IPC Rules

The camera extension runs sandboxed. Be conservative with IPC.

Extension-to-app signaling:

- Use Darwin notifications via `CFNotificationCenterGetDarwinNotifyCenter()` for
  lightweight start/stop signals.
- Use app-group `UserDefaults(suiteName:)` for shared state.
- Do not rely on app-group defaults for instant cross-process signaling.
- Do not use `DistributedNotificationCenter` from the extension to the app; it is
  blocked by the extension sandbox in practice.

Sink stream lifecycle:

- `CMIOStreamCopyBufferQueue` plus `CMIODeviceStartStream` establishes the sink
  connection.
- After `CMIODeviceStopStream`, `CMIODeviceStartStream` can resume polling; the
  queue survives.
- The app discovers the CMIO device and caches device/stream IDs. Deferred
  `startStream` is expected.
- The sink stream is selected by stream index 1 because the extension creates
  the source stream first and sink stream second, and the CMIO C API does not
  expose stream direction reliably for this lookup.

## Extension Versioning

When changing code that ships in the `Extension` target, including relevant
`Shared/` code, bump `CURRENT_PROJECT_VERSION` in `project.yml`.

The installer compares the extension `bundleVersion`. If it is unchanged, macOS
can keep a stale extension running. Verify logs show an update path such as
`Updating extension: vN -> vM`, not `Extension already up to date`.

`MARKETING_VERSION` is the user-facing app version. `CURRENT_PROJECT_VERSION` is
the build number that controls extension replacement.

## Source And Credential Storage

Camera sources are stored as JSON by `SourceStorage`. Credentials are stored in
Keychain by `KeychainService`.

Keep credentials out of:

- logs
- persisted source JSON
- screenshots
- UI text that can be copied accidentally
- test fixtures that look like real user data

Connection status is runtime state managed by `SourceManager`; do not persist it
on `CameraSource`.

## Tests And Coverage

Any new behavior must land with tests that exercise it. This is especially
important for:

- guided setup completion and resume decisions
- app-version-scoped setup reset behavior
- app-group or `UserDefaults` state
- Keychain or credential-stripping behavior
- camera extension state derivation
- audio demand and stream-coordinator behavior
- jitter buffer, NAL/AVCC, preview downscaling, and decoder behavior

Keep setup decision logic pure where possible, using `SetupLaunchDecision` and
`SetupStateStore` patterns so behavior is testable without AppKit.

## Website

The site in `website/` is independent from the macOS app build. It is a Next.js
16 App Router project on React 19 and TypeScript, styled with Tailwind CSS 4.

Keep links and release references consistent with the canonical public GitHub
repository. The download link should point at a release that actually exists.

## Public Documentation

`CHANGELOG.md` is public-facing. Write for end users, not internal reviewers.
Avoid internal implementation names unless they are necessary to explain a user
visible change.

`ACKNOWLEDGEMENTS.md` carries third-party attribution. Preserve applicable
license notices when changing acknowledgement wording.

Do not commit local machine paths, private planning notes, personal credentials,
provisioning profiles, certificates, build artifacts, or generated Xcode project
files.

## Workflow

- Do not `git push` unless explicitly asked.
- Keep changes small and buildable.
- Commit at logical checkpoints after the chunk is written, reviewed, and
  verified.
- Documentation-only commits must include `[ci skip]` in the commit title.
- Use present-tense, imperative commit messages.
- Preserve the generated-project workflow: change `project.yml`, then regenerate
  with `xcodegen generate`.
- If a change touches platform behavior, prefer Apple's documented APIs and
  verify assumptions against current Apple documentation or local SDK headers.
