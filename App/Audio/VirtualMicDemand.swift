import Foundation

/// Whether an app is using the LemurCam virtual microphone, as this process knows
/// it. The driver posts `consumerStarted` from StartIO and `consumerStopped` from
/// StopIO, and from Initialize for a restarted coreaudiod. Those are fire-and-forget
/// Darwin notifications: one that fired before this app registered is never
/// replayed, so at launch the device's own running state is read instead.
///
/// That read is a CoreAudio call and runs on `halQueue`, never the main thread. At
/// launch it is the process's first CoreAudio call, which initializes the HAL client
/// and can block on a busy coreaudiod: about 30 ms when idle, far longer right
/// after boot.
@MainActor
internal final class VirtualMicDemand {
    /// Whether an app is using the virtual microphone.
    private(set) var hasConsumers = false

    /// Called after each notification or device read is applied, whether or not it
    /// changed `hasConsumers`.
    var onUpdate: (() -> Void)?

    private let probe: @Sendable () -> Bool
    private let halQueue = DispatchQueue(label: "com.steelbrain.LemurCam.audioHAL", qos: .userInitiated)
    /// Counts consumer notifications. A device read that a notification overtook is
    /// older than that notification, so its result is dropped.
    private var notificationCount = 0

    /// `probe` reads whether the virtual microphone is running; it is called on
    /// `halQueue`.
    init(probe: @escaping @Sendable () -> Bool) {
        self.probe = probe
        observeConsumerNotifications()
    }

    deinit {
        let center = CFNotificationCenterGetDarwinNotifyCenter()
        CFNotificationCenterRemoveEveryObserver(center, Unmanaged.passUnretained(self).toOpaque())
    }

    /// Apply a consumer notification from the driver.
    func consumerChanged(active: Bool) {
        notificationCount &+= 1
        hasConsumers = active
        onUpdate?()
    }

    /// Read the device's running state off the main thread and apply it, unless a
    /// consumer notification arrived while the read ran.
    func refreshFromDevice() async {
        let notificationsBefore = notificationCount
        let readIsRunning = probe
        let isRunning = await withCheckedContinuation { continuation in
            halQueue.async { continuation.resume(returning: readIsRunning()) }
        }
        guard notificationCount == notificationsBefore else { return }
        hasConsumers = isRunning
        onUpdate?()
    }

    private func observeConsumerNotifications() {
        let center = CFNotificationCenterGetDarwinNotifyCenter()
        let observer = Unmanaged.passUnretained(self).toOpaque()

        CFNotificationCenterAddObserver(
            center, observer,
            { _, observer, _, _, _ in
                guard let observer else { return }
                let demand = Unmanaged<VirtualMicDemand>.fromOpaque(observer).takeUnretainedValue()
                DispatchQueue.main.async { demand.consumerChanged(active: true) }
            },
            LEMUR_AUDIO_NOTIFY_CONSUMER_STARTED as CFString, nil, .deliverImmediately
        )

        CFNotificationCenterAddObserver(
            center, observer,
            { _, observer, _, _, _ in
                guard let observer else { return }
                let demand = Unmanaged<VirtualMicDemand>.fromOpaque(observer).takeUnretainedValue()
                DispatchQueue.main.async { demand.consumerChanged(active: false) }
            },
            LEMUR_AUDIO_NOTIFY_CONSUMER_STOPPED as CFString, nil, .deliverImmediately
        )
    }
}
