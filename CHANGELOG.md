# Changelog

## Unreleased

### New

- The Resolution and Frame Rate settings take effect right away, without restarting LemurCam. An app that picks its own resolution or frame rate gets it, with black bars instead of stretching when the picture's shape differs. Otherwise the camera uses your setting.
- 60 fps cameras now come through at 60 fps. LemurCam sends frames on at each camera's own frame rate. It used a fixed 30 fps, which dropped every other frame of a 60 fps camera and added about half a second of delay.
- ONVIF cameras with a self-signed HTTPS certificate can be added. LemurCam shows the certificate's SHA-256 fingerprint, asks whether to trust it, and remembers the answer for that camera. If the certificate changes later, LemurCam stops and asks again.
- An ONVIF camera outside your local network can be reached over plain HTTP once you turn on Allow Unencrypted HTTP for that camera.
- Before streaming from an ONVIF camera, LemurCam checks that the device at its saved address is that camera. If another device answers there, LemurCam looks for the camera on your network and doesn't send your login to the other device.
- ONVIF cameras can be added by an IPv6 address.
- Camera audio with more than two channels now plays on the LemurCam Microphone.
- About LemurCam has an Acknowledgements button that shows the third-party license notices.

### Video and connections

- The 15-second connection timeout is now enforced, and switching cameras stops a connection in progress right away.
- LemurCam reconnects when a camera sends video that won't decode, and waits for the next keyframe after packet loss.
- Fixed the previous camera's last frame showing after switching cameras.
- The active camera shows as disconnected while no app is using it, and the menu bar popover no longer connects to the camera while it shows a setup message.
- The Local Network warning appears only when a camera on your network can't be reached at all, not when it times out or answers with an error.
- Less delay after a network hiccup: frames that piled up are dropped once they're no longer needed.
- Fixed LemurCam losing its connection to the LemurCam camera after the camera was turned off, repaired or replaced.

### ONVIF cameras

- Fixed ONVIF requests that some cameras rejected as malformed, and logins failing on cameras whose clock differs from your Mac's.
- ONVIF requests now time out instead of waiting indefinitely, and a camera that can't be reached shows the camera's own answer, such as a refused login, instead of "Could not reach camera".
- A wrong ONVIF password is reported after one failed login, so a camera that locks its account after failed logins isn't sent the password twice.
- Cameras that moved to a new IP address are found again more reliably, and their saved stream address moves with them.
- Discovery prefers a camera's HTTP address when it offers HTTP and HTTPS, and keeps an HTTPS camera's address as it was found.
- Stream addresses with a password that holds an @, #, ? or space now connect.

### Saved cameras and logins

- Passwords no longer appear in saved or shown camera URLs, including logins written in a URL's path or query.
- A camera isn't saved when the Keychain won't store its login. When your cameras can't be saved, an add, edit or removal is undone and Settings says so.
- Your saved cameras are kept when their file is damaged or can't be read, and LemurCam says why instead of showing no cameras.
- The RTSP URL field accepts an @ after an IPv4 address and port, as many cameras' URLs have, and says what to fix in a URL it can't use.
- Fixed several cases where pasting or editing a URL with a login lost the password you had typed.

### LemurCam Microphone

- Fixed the microphone replaying old audio when a call started, keeping a long delay after a burst of audio, dropping out on every network stall, and staying silent when LemurCam opened after a call had started.
- Fixed LemurCam keeping your camera connected for the microphone after the microphone was removed or macOS restarted its audio system.
- The microphone's status no longer spins forever when the helper doesn't answer, Try Again and Re-check Now do what they say, guided setup offers an update when one is needed, and the reason for a failure stays shown until you act on it.
- After an update, LemurCam asks you to restart when an older version of its audio helper is still running.

### Setup and settings

- Fixed the Shortcuts actions Switch Camera, Get Current Camera and Get Connection Status, which did nothing.
- Fixed Restart and the launch checks stalling on the quit prompt, the Logs pane no longer scrolling to new lines once full, and Launch at Login not showing a change made in System Settings.
- The launch banner stays closed for the rest of the session once you close it.
- A failed camera install or repair keeps its reason shown, and Try Again redoes a failed repair.

### Security

- The microphone driver is installed as a root-owned copy that other apps can't change, only from LemurCam's own app, and never downgraded. LemurCam offers to reinstall a driver that isn't installed that way.
- The audio helper quits when it's idle, so an updated LemurCam runs its own version of the helper.
- LemurCam refuses oversized or deeply nested replies from cameras, and accepts discovery replies only to its own search.

### Other

- Updated IPCamKit to 0.5.0.

## v1.5

- Fixed the Settings window on macOS 27, where a frosted bar hid the top of each page and the sidebar button sat in the middle of the toolbar

## v1.4

- Updated IPCamKit to pull in fixes for TP-Link Tapo cameras

## v1.3

- Refreshed the Setup & Status screen with at-a-glance device cards that match the guided-setup look, each showing its status and next action in one place
- Clearer camera status: if you’ve turned the LemurCam camera off, it now says “Turned off” with a way to re-enable it, instead of mislabeling it as still needing your approval
- More reliable updates: after updating LemurCam, it now notices when the camera needs an app restart — or a full Mac restart — to finish, and tells you up front instead of appearing ready while still running the previous version
- Added a one-click Repair for the rare case where several conflicting LemurCam camera versions end up installed
- LemurCam now warns you when macOS Local Network privacy may be blocking your IP camera, and points you to the setting that allows it
- Smoother, more fluid video — the virtual camera now runs at 30fps instead of 15fps
- Lower CPU usage while another app is using the camera — fixed a background polling loop that could spike CPU
- A cleaner guided setup: a single, clearer action on the camera step and a more compact window with less empty space
- A more polished guided setup, with smooth animations as each step is set up and completes
- Fixed “Add Camera” in guided setup not opening Settings so you could add your camera
- Fixed the LemurCam Microphone staying silent when an app started using it before LemurCam had launched — sound now starts automatically once LemurCam is running
- Fixed setting up or removing the LemurCam Microphone sometimes reporting an error even though it had actually succeeded

## v1.2

- New guided setup walks you through getting started in three clear steps — first the LemurCam camera, then the optional microphone, then adding your IP camera — with live status for each step
- If LemurCam restarts mid-setup, setup reopens on the first step you haven’t finished yet, so you pick up where you left off instead of skipping ahead
- Updating LemurCam re-runs guided setup so you can re-enable the camera (and the optional microphone) for the new version
- The LemurCam Microphone now passes through your camera’s audio — apps like Zoom and FaceTime hear it automatically when the selected camera has sound, across the audio formats common to IP cameras (AAC, G.711, and L16)
- Simpler microphone setup: a single action handles the whole install, and you can update or remove it later from Settings
- Redesigned settings with an easy-to-navigate sidebar in place of the cramped tabs
- More reliable detection of whether the LemurCam camera is approved and running, including a clear prompt when it still needs your approval
- When the camera just needs one last step, LemurCam now tells you to restart the app — with a one-click “Restart LemurCam” button — instead of asking you to restart your Mac
- Lower CPU usage while the camera is streaming — video now stays in its native format instead of being converted frame by frame
- Fixed camera extension not activating on fresh installs

## v1.1

- Significantly smoother video output — eliminated periodic stutters and frame rate hiccups
- Faster video processing with GPU-accelerated rendering
- Fixed resolution display showing numbers with commas
- Smaller, more compact settings window
- App now requires installation in /Applications
- Universal binary support (Apple Silicon and Intel)
