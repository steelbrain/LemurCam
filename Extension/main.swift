import CoreMediaIO
import Foundation
import os

// MARK: - Crash Handlers

NSSetUncaughtExceptionHandler { exception in
    Log.ext.fault(
        """
        Uncaught exception: \(exception.name.rawValue) \
        — \(exception.reason ?? "no reason") \
        — \(exception.callStackSymbols.joined(separator: "\n"))
        """
    )
}

for sig: Int32 in [SIGABRT, SIGBUS, SIGFPE, SIGILL, SIGSEGV, SIGTRAP] {
    signal(sig) { sigNum in
        let msg = "LemurCam Extension: caught fatal signal\n"
        msg.withCString { ptr in _ = Darwin.write(STDERR_FILENO, ptr, strlen(ptr)) }
        signal(sigNum, SIG_DFL)
        raise(sigNum)
    }
}

// MARK: - Start Extension

// Publish the running extension's version so the app can detect a stale
// post-upgrade extension (see ExtensionUpgradeDecision). macOS can keep an old
// version resident after an in-place update, so this is the app's ground truth
// for "is the shipped code actually live?".
//
// ORDERING INVARIANT: this MUST run before `startService` below. The app only
// trusts the stamped version when the CMIO device is live; stamping first
// guarantees that by the time the device is serving, the serving extension's
// version is already published. Stamping after `startService` would open a
// window where a live device reports a stale/absent version.
LemurCamConfig.recordRunningExtensionVersion()

internal let providerSource = ExtensionProviderSource(clientQueue: nil)
guard let provider = providerSource.provider else {
    fatalError("Failed to create CMIOExtensionProvider")
}
CMIOExtensionProvider.startService(provider: provider)

CFRunLoopRun()
