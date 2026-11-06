import Foundation

/// Where App Intents find the running app's state. Intents can't use
/// `NSApp.delegate as? AppDelegate`: with `@NSApplicationDelegateAdaptor`, SwiftUI
/// installs its own delegate object, so that cast is always nil.
@MainActor
internal enum IntentContext {
    /// The app's live source manager, or nil before the app delegate registers.
    static var sourceManager: SourceManager? { AppDelegate.shared?.sourceManager }
}
