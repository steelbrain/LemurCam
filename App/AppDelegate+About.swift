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
            content: AboutView { [weak self] in self?.openAcknowledgementsWindow() },
            resizable: false
        )
    }

    /// The third-party notices (the bundled ACKNOWLEDGEMENTS.md), opened from About.
    func openAcknowledgementsWindow() {
        if let window = acknowledgementsWindow {
            window.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }
        acknowledgementsWindow = presentUtilityWindow(
            title: "Acknowledgements",
            content: AcknowledgementsView(markdown: Acknowledgements.load()),
            resizable: true,
            contentSize: AcknowledgementsView.openingSize
        )
    }

    /// Whether the Help, About or Acknowledgements window is open.
    var hasUtilityWindowOpen: Bool {
        helpWindow != nil || aboutWindow != nil || acknowledgementsWindow != nil
    }

    /// Drops the reference to `window` if it is the Help, About or Acknowledgements
    /// window, and returns whether it was one of them.
    func forgetUtilityWindow(_ window: NSWindow) -> Bool {
        if window === helpWindow {
            helpWindow = nil
        } else if window === aboutWindow {
            aboutWindow = nil
        } else if window === acknowledgementsWindow {
            acknowledgementsWindow = nil
        } else {
            return false
        }
        return true
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
    /// delegate, no release-on-close). The SwiftUI root sizes itself, from
    /// `contentSize` when given, which a resizable root's flexible frame keeps.
    private func presentUtilityWindow(
        title: String,
        content: some View,
        resizable: Bool,
        contentSize: NSSize = .zero
    ) -> NSWindow {
        var styleMask: NSWindow.StyleMask = [.titled, .closable]
        if resizable { styleMask.insert(.resizable) }
        let window = NSWindow(
            contentRect: NSRect(origin: .zero, size: contentSize),
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
