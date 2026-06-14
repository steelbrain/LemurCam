# Changelog

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
