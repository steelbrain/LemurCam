/// Runs a fetch the add/edit form starts, within
/// `ONVIFTimeout.interactiveFetch`, and hands its result back on the main actor.
internal enum SourceFormFetch {
    @MainActor
    static func run<Value: Sendable>(
        _ operation: @escaping @Sendable () async throws -> Value,
        then completion: @escaping @MainActor (Result<Value, any Error>) -> Void
    ) {
        Task {
            do {
                completion(.success(try await ONVIFTimeout.run(seconds: ONVIFTimeout.interactiveFetch, operation)))
            } catch {
                completion(.failure(error))
            }
        }
    }
}
