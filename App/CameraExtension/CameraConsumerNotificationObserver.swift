import CoreFoundation

/// Starts following the camera extension's consumer notifications, calling
/// `onChange` on the main thread with whether an external app started (true) or
/// stopped (false) using the virtual camera, and returns what keeps them coming:
/// releasing it removes the observers. Injected so tests never listen to the real
/// notifications, which every LemurCam camera on the Mac posts.
internal typealias CameraConsumerObserving = (
    _ onChange: @escaping @MainActor @Sendable (Bool) -> Void
) -> AnyObject?

/// Observes the extension's `consumerStarted` and `consumerStopped` Darwin
/// notifications. They are system-wide, so a running LemurCam's camera reaches every
/// observer in every process. Retain the instance for as long as notifications are
/// wanted; `deinit` removes the observers.
internal final class CameraConsumerNotificationObserver: Sendable {
    private let onChange: @MainActor @Sendable (Bool) -> Void

    init(onChange: @escaping @MainActor @Sendable (Bool) -> Void) {
        self.onChange = onChange
        let center = CFNotificationCenterGetDarwinNotifyCenter()
        let observer = Unmanaged.passUnretained(self).toOpaque()

        CFNotificationCenterAddObserver(
            center, observer,
            { _, observer, _, _, _ in
                guard let observer else { return }
                let deliver = Unmanaged<CameraConsumerNotificationObserver>.fromOpaque(observer)
                    .takeUnretainedValue().onChange
                DispatchQueue.main.async { deliver(true) }
            },
            LemurCamConfig.consumerStartedNotification, nil, .deliverImmediately
        )

        CFNotificationCenterAddObserver(
            center, observer,
            { _, observer, _, _, _ in
                guard let observer else { return }
                let deliver = Unmanaged<CameraConsumerNotificationObserver>.fromOpaque(observer)
                    .takeUnretainedValue().onChange
                DispatchQueue.main.async { deliver(false) }
            },
            LemurCamConfig.consumerStoppedNotification, nil, .deliverImmediately
        )
    }

    deinit {
        let center = CFNotificationCenterGetDarwinNotifyCenter()
        CFNotificationCenterRemoveEveryObserver(center, Unmanaged.passUnretained(self).toOpaque())
    }
}
