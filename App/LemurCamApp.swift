import os
import SwiftUI

@main
internal struct LemurCamApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate

    init() {
        NSSetUncaughtExceptionHandler { exception in
            Log.app.fault(
                """
                Uncaught exception: \(exception.name.rawValue) \
                — \(exception.reason ?? "no reason") \
                — \(exception.callStackSymbols.joined(separator: "\n"))
                """
            )
        }
        for sig: Int32 in [SIGABRT, SIGBUS, SIGFPE, SIGILL, SIGSEGV, SIGTRAP] {
            signal(sig) { sigNum in
                let msg = "LemurCam: caught fatal signal\n"
                msg.withCString { ptr in _ = Darwin.write(STDERR_FILENO, ptr, strlen(ptr)) }
                signal(sigNum, SIG_DFL)
                raise(sigNum)
            }
        }
    }

    var body: some Scene {
        Settings {
            EmptyView()
        }
        .commands {
            // Replace the standard About panel, whose copyright text can't link
            // to lemur.cam, with the custom AboutView that uses clickable Links.
            CommandGroup(replacing: .appInfo) {
                Button("About LemurCam") {
                    appDelegate.showAboutPanel()
                }
            }
            CommandGroup(replacing: .appSettings) {
                Button("Settings\u{2026}") {
                    appDelegate.openSettings()
                }
                .keyboardShortcut(",", modifiers: .command)
            }
            // Replace the default "LemurCam Help" item, which otherwise reports that
            // help isn't available, with the in-app guide.
            CommandGroup(replacing: .help) {
                Button("LemurCam Help") {
                    appDelegate.openHelpWindow()
                }
                .keyboardShortcut("?", modifiers: .command)
            }
        }
    }
}
