import Foundation

/// The three ordered phases of the guided setup wizard.
///
/// Step 1 installs the required camera system extension (and optionally restarts
/// the app to bring the device live), step 2 sets up the optional microphone
/// audio driver, and step 3 optionally adds an IP camera feed. Ordering is
/// encoded in the raw value so `next`/`previous` stay in lockstep with display.
internal enum SetupStep: Int, CaseIterable, Identifiable {
    case camera
    case microphone
    case addCamera

    internal var id: Int { rawValue }

    /// 1-based position shown to the user ("Step 2 of 3").
    internal var displayNumber: Int { rawValue + 1 }

    /// The next step, or nil if this is already the last one.
    internal var next: Self? { Self(rawValue: rawValue + 1) }

    /// The previous step, or nil if this is already the first one.
    internal var previous: Self? { Self(rawValue: rawValue - 1) }

    /// Short title shown in the step indicator.
    internal var title: String {
        switch self {
        case .camera: return "Camera"
        case .microphone: return "Microphone"
        case .addCamera: return "Add a Camera"
        }
    }

    /// Total number of steps, for the "of N" portion of the indicator.
    internal static var total: Int { allCases.count }
}

/// Pure decision for which setup step (if any) the wizard should auto-open to on
/// launch. Kept out of `AppDelegate` so the launch behavior is unit testable
/// without UserDefaults or AppKit.
///
/// Each step has its own persisted "done" flag, all false by default. A flag is
/// set only when the user explicitly advances past (or finishes) that step —
/// never by an install completing or by a restart. The wizard resumes on the
/// first step not yet marked done, so a restart during step 1 (e.g. after
/// approving the camera extension) reopens on step 1 — with the now-live camera
/// shown ready — rather than skipping ahead. Once every step is done, the wizard
/// no longer auto-opens — until the app updates, which resets every flag so setup
/// runs again for the new version (see `needsResetForVersion`).
internal enum SetupLaunchDecision {
    /// Whether persisted completion flags belong to a different app version (or
    /// none yet) and must be discarded so guided setup re-runs for the current
    /// version. True on first launch and after any app update.
    internal static func needsResetForVersion(storedVersion: String?, currentVersion: String) -> Bool {
        storedVersion != currentVersion
    }

    /// - Parameters:
    ///   - step1Done: whether the user advanced past the camera step.
    ///   - step2Done: whether the user advanced past the microphone step.
    ///   - step3Done: whether the user finished or skipped the add-camera step.
    /// - Returns: the first step not yet done, or nil if all are done.
    internal static func step(step1Done: Bool, step2Done: Bool, step3Done: Bool) -> SetupStep? {
        if !step1Done { return .camera }
        if !step2Done { return .microphone }
        if !step3Done { return .addCamera }
        return nil
    }
}

/// The footer's leading (left) slot.
internal enum SetupLeadingButton: Equatable {
    /// Return to the previous step (any step after the first).
    case back
    /// Defer the whole wizard. Only on the first step, and only while the camera
    /// is not yet ready — once it is, `SetupPrimaryButton.continueStep` takes over.
    case setUpLater
}

/// The footer's trailing (right) primary slot.
internal enum SetupPrimaryButton: Equatable {
    /// Advance to the next step.
    case continueStep
    /// Advance past the optional microphone step without setting it up.
    case skip
    /// Finish the wizard (last step).
    case done
}

/// Pure decision for which footer buttons the wizard shows, kept out of the view
/// so the "never duplicate the do-later affordance with Continue" rule is unit
/// testable without SwiftUI.
///
/// On the camera step, "Set Up Later" (leading) and "Continue" (primary) are
/// mutually exclusive and gated on whether the camera is ready: while it is not,
/// the only footer action is "Set Up Later"; once it is, that slot empties and
/// "Continue" appears. A disabled "Continue" is therefore never shown next to
/// "Set Up Later". Later steps always offer "Back" plus a step-appropriate
/// primary action.
internal enum SetupFooterButtons {
    /// The leading button, or nil when the slot is empty (camera step, ready).
    internal static func leading(for step: SetupStep, cameraStepDone: Bool) -> SetupLeadingButton? {
        if step.previous != nil { return .back }
        return cameraStepDone ? nil : .setUpLater
    }

    /// The primary button, or nil when the slot is empty (camera step, not ready).
    internal static func primary(
        for step: SetupStep, cameraStepDone: Bool, micReady: Bool
    ) -> SetupPrimaryButton? {
        switch step {
        case .camera: return cameraStepDone ? .continueStep : nil
        case .microphone: return micReady ? .continueStep : .skip
        case .addCamera: return .done
        }
    }
}

/// Pure gate for advancing past the camera step. The camera must be actually live
/// (`.ready`) before the wizard offers "Continue"; a pending app restart or Mac
/// reboot is a required action the user must take first, so "Continue" never sits
/// beside a still-required "Restart". Kept out of the view so it's unit-testable.
internal enum SetupCameraGate {
    static func canAdvance(_ status: CameraExtensionStatus) -> Bool {
        status == .ready
    }
}

/// Persists guided-setup completion, scoped to a specific app version. The three
/// per-step "done" flags are cleared whenever the app version changes, so each
/// new version re-runs setup; completion is never preserved across versions.
///
/// Wraps an injected `UserDefaults` (the app group is not needed — this is
/// app-local state), so the version-scoping behavior is unit testable without
/// AppKit. The reset decision itself lives in `SetupLaunchDecision`.
internal struct SetupStateStore {
    private let defaults: UserDefaults
    private let version: String

    private static let step1Key = "LemurCam.setupStep1Done"
    private static let step2Key = "LemurCam.setupStep2Done"
    private static let step3Key = "LemurCam.setupStep3Done"
    private static let versionKey = "LemurCam.setupStateVersion"

    /// - Parameters:
    ///   - defaults: backing store for the completion flags.
    ///   - version: the running app's version identity; completion is scoped to it.
    internal init(defaults: UserDefaults, version: String) {
        self.defaults = defaults
        self.version = version
    }

    /// Discard completion recorded under a different app version (including first
    /// launch) and record the current version, so a new version re-runs setup.
    /// Call once at launch before reading state. Returns whether it reset.
    @discardableResult
    internal func resetForVersionChangeIfNeeded() -> Bool {
        guard SetupLaunchDecision.needsResetForVersion(
            storedVersion: defaults.string(forKey: Self.versionKey),
            currentVersion: version
        ) else { return false }
        defaults.removeObject(forKey: Self.step1Key)
        defaults.removeObject(forKey: Self.step2Key)
        defaults.removeObject(forKey: Self.step3Key)
        defaults.set(version, forKey: Self.versionKey)
        return true
    }

    /// Record that the user explicitly completed a step.
    internal func markComplete(_ step: SetupStep) {
        defaults.set(true, forKey: key(for: step))
    }

    /// Whether the given step has been completed under the current version.
    internal func isComplete(_ step: SetupStep) -> Bool {
        defaults.bool(forKey: key(for: step))
    }

    /// The step the wizard should auto-open at, or nil once setup is complete.
    internal func launchStep() -> SetupStep? {
        SetupLaunchDecision.step(
            step1Done: defaults.bool(forKey: Self.step1Key),
            step2Done: defaults.bool(forKey: Self.step2Key),
            step3Done: defaults.bool(forKey: Self.step3Key)
        )
    }

    private func key(for step: SetupStep) -> String {
        switch step {
        case .camera: return Self.step1Key
        case .microphone: return Self.step2Key
        case .addCamera: return Self.step3Key
        }
    }
}
