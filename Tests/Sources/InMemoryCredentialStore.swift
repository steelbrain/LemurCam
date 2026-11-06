import Foundation
@testable import LemurCam

/// A `CredentialStore` that never touches the real Keychain. `failReads` makes every
/// `retrieve` throw, as a locked or damaged Keychain does, and `failSaves` every
/// `save`. Every call is recorded so tests can assert that nothing was saved or
/// deleted.
internal final class InMemoryCredentialStore: CredentialStore {
    enum Call: Equatable {
        case save(UUID)
        case retrieve(UUID)
        case delete(UUID)
    }

    struct ReadFailure: Error {}
    struct SaveFailure: Error {}

    private(set) var stored: [UUID: SourceCredentials] = [:]
    private(set) var calls: [Call] = []
    var failReads = false
    var failSaves = false

    func save(credentials: SourceCredentials, for sourceID: UUID) throws {
        calls.append(.save(sourceID))
        if failSaves { throw SaveFailure() }
        stored[sourceID] = credentials
    }

    func retrieve(for sourceID: UUID) throws -> SourceCredentials? {
        calls.append(.retrieve(sourceID))
        if failReads { throw ReadFailure() }
        return stored[sourceID]
    }

    func delete(for sourceID: UUID) {
        calls.append(.delete(sourceID))
        stored[sourceID] = nil
    }

    var writes: [Call] {
        calls.filter { call in
            if case .retrieve = call { return false }
            return true
        }
    }
}
