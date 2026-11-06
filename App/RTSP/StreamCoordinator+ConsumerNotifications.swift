// MARK: - Camera Consumer Notifications

extension StreamCoordinator {
    /// Follow external camera consumers: the extension's consumer notifications,
    /// which `observe` registers for, and what the model learns from CMIO. Returns
    /// what keeps the notifications coming, which the coordinator holds until
    /// `deinit`.
    func observeConsumerChanges(using observe: ConsumerObserving) -> AnyObject? {
        let registration = observe { [weak self] active in
            self?.cameraConsumerChanged(active: active)
        }

        // The extension posts nothing when it dies or its device is replaced, and
        // the model's discovery probe decides whether the sink stream starts: take
        // both from the model, so a consumer that is gone stops the stream and one
        // the sink serves gets frames.
        model.onExternalConsumerChange = { [weak self] hasConsumer in
            self?.cameraConsumerChanged(active: hasConsumer)
        }
        return registration
    }
}
