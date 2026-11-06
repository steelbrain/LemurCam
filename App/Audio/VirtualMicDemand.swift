import CoreFoundation
import os

/// Starts watching the HAL device list, calling `onChange` on the given queue after
/// each change, and returns what keeps the listener installed. Called on that queue.
internal typealias AudioDeviceListObserving = @Sendable (
    _ queue: DispatchQueue, _ onChange: @escaping @Sendable () -> Void
) -> AnyObject?

/// Whether an app is using the LemurCam virtual microphone, as this process knows
/// it. The driver posts `consumerStarted` from StartIO and `consumerStopped` from
/// StopIO, and from Initialize for a restarted coreaudiod. Those are fire-and-forget
/// Darwin notifications: one that fired before this app registered is never
/// replayed, so at launch the device's own running state is read instead. It is
/// read again after every HAL device-list change: removing the driver (the helper
/// moves it out and restarts coreaudiod) ends a recording app's IO without StopIO,
/// and the removed driver never runs Initialize, so no `consumerStopped` comes.
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
    private let makeDeviceListObserver: AudioDeviceListObserving
    private let deviceListObserver = OSAllocatedUnfairLock<AnyObject?>(uncheckedState: nil)
    private var isObservingDeviceList = false
    private let halQueue = DispatchQueue(label: "com.steelbrain.LemurCam.audioHAL", qos: .userInitiated)
    /// Counts consumer notifications. A device read that a notification overtook is
    /// older than that notification, so its result is dropped.
    private var notificationCount = 0

    /// `probe` reads whether the virtual microphone is running, and
    /// `makeDeviceListObserver` installs the HAL device-list listener. Both are
    /// called on `halQueue`.
    init(probe: @escaping @Sendable () -> Bool, makeDeviceListObserver: @escaping AudioDeviceListObserving) {
        self.probe = probe
        self.makeDeviceListObserver = makeDeviceListObserver
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

    /// Re-read the device after every HAL device-list change, from now on. The
    /// listener is installed on `halQueue`, ahead of any read queued after this.
    func observeDeviceList() {
        guard !isObservingDeviceList else { return }
        isObservingDeviceList = true
        let makeObserver = makeDeviceListObserver
        let observer = deviceListObserver
        let queue = halQueue
        let onChange: @Sendable () -> Void = { [weak self] in
            Task { @MainActor [weak self] in await self?.refreshFromDevice() }
        }
        halQueue.async {
            let token = makeObserver(queue, onChange)
            observer.withLockUnchecked { $0 = token }
        }
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
