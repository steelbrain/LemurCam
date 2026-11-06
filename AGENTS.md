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
  `Shared/DriverInstall/` is the helper's audio-driver install and removal
  pipeline (staging, ownership audit, signature and downgrade checks, atomic
  swap) and its `coreaudiod` restart. It is compiled into `Helper` and into the
  app, which uses only its read-only check of whether the installed driver is
  sealed to root (`DriverInstaller.installedCopyIsSealed`) and otherwise has it
  for the unit tests; `project.yml` excludes it from `Extension`.
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
scripts/ci.sh           # Full local CI: SwiftLint, build, tests (signed)
scripts/ci.sh --unsigned # Same, with CODE_SIGNING_ALLOWED=NO like GitHub CI
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

SwiftLint must be exactly the version `.swiftlint.yml` pins with
`swiftlint_version` (0.65.1). Any other version makes `swiftlint lint` exit 2
with only a one-line warning, so `scripts/ci.sh` checks `swiftlint version`
first and stops with an error naming the required version. Homebrew's formula
can be a different version; install the release's `portable_swiftlint.zip` the
way `.github/workflows/ci.yml` does (steps in `README.md`). To move to a new
SwiftLint, bump `swiftlint_version` and the workflow's `SWIFTLINT_VERSION`
together, along with the version README.md and this guide name.

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

The Preview settings tab intentionally creates preview demand, and so does the
menu bar popover while it shows the live preview: only when the camera is set up
(`SetupCoordinator.cameraStatus == .ready`); in every other camera state it shows
a setup or issue message instead. `PreviewDemandDecision` and `PopoverView` share
that mapping (`ExtensionState`), and `AppDelegate` re-evaluates demand when the
camera status changes. Showing neither (closing the popover or leaving it on a
setup or issue message, and closing Settings or switching it to another pane)
drops preview demand, so streams can pause when no external app is using the
camera or the microphone.

The Resolution and Frame Rate settings take effect without a restart. The app
stores them in the app group, which only the app can read. The camera extension
offers every resolution at 30 and 60 fps on both of its streams
(`StreamFormatTable`), starting in the default 1080p at 60 fps. The app sets the
chosen format on the sink stream (`SinkStreamFormatWriter`, see Extension And
IPC Rules) each time discovery finds a new device and each time the setting
changes. The extension makes it the source stream's default
(`SourceFormatState`): it applies at once while no app uses the camera, and
otherwise when the last consumer stops, so the app never changes the format
under a running consumer. An app that picks its own format or frame rate on the
source stream gets it at once, and keeps it until the next change. The
extension scales the app's frames to the active resolution, letterboxed, with a
`VTPixelTransferSession` and a pixel buffer pool per format, passes frames that
already match through without a copy, and paces them to the active frame rate
(`ExtensionDeviceRuntime`, `FramePacer`). Its own placeholder is drawn at the
active resolution.

## Streaming And Demand

The app supports direct RTSP URLs and ONVIF cameras. ONVIF discovery uses
WS-Discovery UDP probing. Stream decoding uses `IPCamKit`, VideoToolbox, and a
jitter buffer before frames are converted to sample buffers for the extension.

Demand matters. The RTSP pipeline should run only when an external app is using
the virtual camera or the virtual microphone, or when in-app preview is enabled.
Avoid background work that keeps cameras connected with no consumer.

Camera demand comes from the extension's `consumerStarted` / `consumerStopped`
Darwin notifications, a CMIO probe at launch, and `LemurCamModel`'s
`onExternalConsumerChange` reports: no consumer when the device goes away or is
replaced (the extension posts nothing when it dies), and the probe's answer after
each discovery of a new device. When demand drops, `StreamCoordinator` pauses the
pipeline and shows the active camera as disconnected.

Camera audio is decoded in `App/RTSP/AudioDecoder.swift`:

- G.711 mu-law/a-law and L16 are decoded directly.
- AAC is decoded via an AudioToolbox `AudioConverter`.
- Output is converted to 48 kHz Float32 stereo with `AVAudioConverter`.
- Audio production is owned by `StreamCoordinator` and demand-gated by
  `VirtualMicDemand`: the driver's `audioConsumerStarted` /
  `audioConsumerStopped` notifications, plus a read of the device's running
  state, off the main thread, at launch and after every HAL device-list change
  or `coreaudiod` restart (removing the driver ends a recording app's IO
  without StopIO).

Toggling microphone demand must not reconnect a live video stream.

## Extension And IPC Rules

The camera extension runs sandboxed. Be conservative with IPC.

The extension process runs as the system user `_cmiodalassistants`, not as the
logged-in user (`ps` shows it). App-group `UserDefaults(suiteName:)` is a
per-user domain, so the extension and the app each get their own copy of the
app-group defaults: nothing one writes there is visible to the other. Running
`defaults read <app group ID>` as the user reports "Domain not found" even
though the extension writes to it on every start.

Extension-to-app signaling:

- Use Darwin notifications via `CFNotificationCenterGetDarwinNotifyCenter()` for
  lightweight start/stop signals. They are system-wide and do reach the app.
- Read state from CMIO properties of the LemurCam device. For example,
  `kCMIODevicePropertyDeviceIsRunningSomewhere` tells whether any process is
  using the camera (see `CameraConsumerProbe`). It also counts the app's own
  sink stream, so it means "an external consumer" only before the app starts
  that stream.
- Do not use app-group `UserDefaults(suiteName:)` to share state between the
  extension and the app. `runningExtensionVersion` still goes through it, so it
  does not cross today. The extension can't read the Resolution and Frame Rate
  settings there either; they reach it as described below.
- Do not use `DistributedNotificationCenter` from the extension to the app; it is
  blocked by the extension sandbox in practice.

App-to-extension signaling:

- Set standard CMIO properties of the sink stream, which only the app uses.
  Setting `kCMIOStreamPropertyFormatDescription` (to one of the stream's
  `kCMIOStreamPropertyFormatDescriptions`) and `kCMIOStreamPropertyFrameRate`
  reaches the extension's `setStreamProperties` as the sink's active format
  index and frame duration, which the extension takes as the default format.
  The sink offers the same formats as the source for this; it still accepts the
  app's frames at any size.
- A restarted, re-enabled or repaired extension starts over in its default
  format, so the app sets the format again on every newly discovered device.

Sink stream lifecycle:

- `CMIOStreamCopyBufferQueue` plus `CMIODeviceStartStream` establishes the sink
  connection.
- After `CMIODeviceStopStream`, `CMIODeviceStartStream` can resume polling; the
  queue survives.
- The app discovers the CMIO device and caches device/stream IDs. Deferred
  `startStream` is expected.
- Cached IDs are only valid while the device stays registered. Do not assume
  they survive the extension being disabled, re-enabled, repaired, replaced or
  restarted. The app drops the IDs and all sink-stream state when the CMIO
  device list no longer shows the cached device, rediscovers when it returns,
  and re-runs discovery on every `onCameraReady`.
- In the extension, every sink consume completion is checked against the
  session (generation) it was issued under; completions from a stopped or
  replaced session are dropped (`SinkStreamSession`).
- The sink stream is selected by stream index 1 because the extension creates
  the source stream first and sink stream second, and the CMIO C API does not
  expose stream direction reliably for this lookup.

## Extension Versioning

When changing code that ships in the `Extension` target, including relevant
`Shared/` code, bump `CURRENT_PROJECT_VERSION` in `project.yml`.

The installer compares the extension `bundleVersion`. If it is unchanged, macOS
can keep a stale extension running. Verify the app log shows an update path
such as `Updating camera extension: vN → vM`, not
`Camera extension already up to date (vN)`.

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
