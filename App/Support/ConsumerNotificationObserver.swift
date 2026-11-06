import CoreFoundation

/// Starts following consumer notifications, calling `onChange` on the main thread
/// with whether an external app started (true) or stopped (false) using the virtual
/// camera or microphone, and returns what keeps them coming: releasing it removes
/// the observers. Injected so tests never listen to the real notifications, which
/// the LemurCam camera and microphone in use on the Mac post system-wide.
internal typealias ConsumerObserving = (
    _ onChange: @escaping @MainActor @Sendable (Bool) -> Void
) -> AnyObject?

/// Observes a pair of consumer Darwin notifications: the camera extension's
/// (`camera(onChange:)`) or the audio driver's (`microphone(onChange:)`). They are
/// system-wide, so a running LemurCam's camera or microphone reaches every observer
/// in every process. Retain the instance for as long as notifications are wanted;
/// `deinit` removes the observers.
internal final class ConsumerNotificationObserver: Sendable {
    private let onChange: @MainActor @Sendable (Bool) -> Void

    /// The camera extension's `consumerStarted` and `consumerStopped`.
    static func camera(onChange: @escaping @MainActor @Sendable (Bool) -> Void) -> ConsumerNotificationObserver {
        ConsumerNotificationObserver(
            started: LemurCamConfig.consumerStartedNotification,
            stopped: LemurCamConfig.consumerStoppedNotification,
            onChange: onChange
        )
    }

    /// The audio driver's, posted from StartIO and StopIO (`VirtualMicDemand`).
    static func microphone(onChange: @escaping @MainActor @Sendable (Bool) -> Void) -> ConsumerNotificationObserver {
        ConsumerNotificationObserver(
            started: LEMUR_AUDIO_NOTIFY_CONSUMER_STARTED as CFString,
            stopped: LEMUR_AUDIO_NOTIFY_CONSUMER_STOPPED as CFString,
            onChange: onChange
        )
    }

    private init(started: CFString, stopped: CFString, onChange: @escaping @MainActor @Sendable (Bool) -> Void) {
        self.onChange = onChange
        let center = CFNotificationCenterGetDarwinNotifyCenter()
        let observer = Unmanaged.passUnretained(self).toOpaque()

        CFNotificationCenterAddObserver(
            center, observer,
            { _, observer, _, _, _ in
                guard let observer else { return }
                let deliver = Unmanaged<ConsumerNotificationObserver>.fromOpaque(observer)
                    .takeUnretainedValue().onChange
                DispatchQueue.main.async { deliver(true) }
            },
            started, nil, .deliverImmediately
        )

        CFNotificationCenterAddObserver(
            center, observer,
            { _, observer, _, _, _ in
                guard let observer else { return }
                let deliver = Unmanaged<ConsumerNotificationObserver>.fromOpaque(observer)
                    .takeUnretainedValue().onChange
                DispatchQueue.main.async { deliver(false) }
            },
            stopped, nil, .deliverImmediately
        )
    }

    deinit {
        let center = CFNotificationCenterGetDarwinNotifyCenter()
        CFNotificationCenterRemoveEveryObserver(center, Unmanaged.passUnretained(self).toOpaque())
    }
}
