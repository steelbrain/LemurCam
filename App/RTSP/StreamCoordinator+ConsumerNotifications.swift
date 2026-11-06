import CoreFoundation

// MARK: - Camera Consumer Notifications

extension StreamCoordinator {
    /// Follow external camera consumers: the extension's Darwin start/stop
    /// notifications, and what the model learns from CMIO. `deinit` removes the
    /// Darwin observers.
    func observeConsumerChanges() {
        let center = CFNotificationCenterGetDarwinNotifyCenter()
        let observer = Unmanaged.passUnretained(self).toOpaque()

        CFNotificationCenterAddObserver(
            center, observer,
            { _, observer, _, _, _ in
                guard let observer else { return }
                let coord = Unmanaged<StreamCoordinator>.fromOpaque(observer)
                    .takeUnretainedValue()
                DispatchQueue.main.async { coord.cameraConsumerChanged(active: true) }
            },
            LemurCamConfig.consumerStartedNotification, nil, .deliverImmediately
        )

        CFNotificationCenterAddObserver(
            center, observer,
            { _, observer, _, _, _ in
                guard let observer else { return }
                let coord = Unmanaged<StreamCoordinator>.fromOpaque(observer)
                    .takeUnretainedValue()
                DispatchQueue.main.async { coord.cameraConsumerChanged(active: false) }
            },
            LemurCamConfig.consumerStoppedNotification, nil, .deliverImmediately
        )

        // The extension posts nothing when it dies or its device is replaced, and
        // the model's discovery probe decides whether the sink stream starts: take
        // both from the model, so a consumer that is gone stops the stream and one
        // the sink serves gets frames.
        model.onExternalConsumerChange = { [weak self] hasConsumer in
            self?.cameraConsumerChanged(active: hasConsumer)
        }
    }
}
