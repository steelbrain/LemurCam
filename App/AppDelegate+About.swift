import AppKit
import SwiftUI

extension AppDelegate {
    /// A custom About window. We don't use `orderFrontStandardAboutPanel` because
    /// the standard panel's credits text view doesn't reliably make links
    /// clickable; `AboutView` uses SwiftUI `Link`s that always open in the browser.
    @objc func showAboutPanel() {
        if let window = aboutWindow {
            window.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }
        aboutWindow = presentUtilityWindow(
            title: "About LemurCam",
            content: AboutView(),
            resizable: false
        )
    }

    /// The in-app Help window. Replaces the default, empty "Help isn't available"
    /// menu item with a real, scrollable guide (`HelpView`).
    @objc func openHelpWindow() {
        if let window = helpWindow {
            window.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }
        helpWindow = presentUtilityWindow(
            title: "LemurCam Help",
            content: HelpView(),
            resizable: true
        )
    }

    /// Build, retain-via-return, and front a simple SwiftUI-hosted window, matching
    /// how `openSettings`/`openSetupWindow` present their panels (activation policy,
    /// delegate, no release-on-close). The SwiftUI root sizes itself.
    private func presentUtilityWindow(
        title: String,
        content: some View,
        resizable: Bool
    ) -> NSWindow {
        var styleMask: NSWindow.StyleMask = [.titled, .closable]
        if resizable { styleMask.insert(.resizable) }
        let window = NSWindow(
            contentRect: .zero,
            styleMask: styleMask,
            backing: .buffered,
            defer: false
        )
        window.title = title
        window.contentView = NSHostingView(rootView: content)
        window.isReleasedWhenClosed = false
        window.delegate = self
        window.center()
        NSApp.setActivationPolicy(.regular)
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        return window
    }
}
