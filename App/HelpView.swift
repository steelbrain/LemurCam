import SwiftUI

/// In-app help. A short, scrollable guide that mirrors how LemurCam actually
/// behaves — first-time approval, adding a camera, demand-driven streaming, the
/// optional microphone, and the handful of things that usually go wrong. Kept
/// deliberately brief; deeper docs live at lemur.cam.
internal struct HelpView: View {
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                header
                ForEach(Self.topics) { topic in
                    HelpTopicCard(topic: topic)
                }
                footer
            }
            .padding(24)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .frame(width: Tuning.helpWindowWidth, height: Tuning.helpWindowHeight)
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("LemurCam Help")
                .font(.largeTitle.bold())
            Text("Point an IP camera at your Mac, and any app can use it as a webcam.")
                .font(.title3)
                .foregroundStyle(.secondary)
        }
    }

    private var footer: some View {
        VStack(alignment: .leading, spacing: 4) {
            Divider()
            HStack(spacing: 4) {
                Text("More guides and downloads at")
                    .foregroundStyle(.secondary)
                if let siteURL = URL(string: "https://lemur.cam") {
                    Link("lemur.cam", destination: siteURL)
                }
            }
            .font(.callout)
        }
    }

    private static let topics: [HelpTopic] = [
        HelpTopic(
            symbol: "checklist",
            title: "First, approve the camera",
            body: """
            Open **Set Up LemurCam** from the menu bar icon. macOS will ask you to \
            approve the LemurCam camera in System Settings — that approval happens \
            outside the app, so flip back once you've allowed it. After approving, \
            restart LemurCam so the virtual camera comes to life.
            """
        ),
        HelpTopic(
            symbol: "web.camera",
            title: "Add a camera",
            body: """
            In **Settings ▸ Cameras**, add a source by its RTSP URL (it starts with \
            `rtsp://`), or let ONVIF discovery find cameras on your network. Any \
            username and password you enter is kept in your macOS Keychain — never in \
            plain text, logs, or the camera list.
            """
        ),
        HelpTopic(
            symbol: "video.fill",
            title: "Use it in any app",
            body: """
            Pick **LemurCam** as the camera in Zoom, Meet, FaceTime, OBS — wherever you \
            choose a webcam. LemurCam only connects to your camera while something is \
            actually watching: an app using the feed, or the in-app preview. With no \
            viewers, it stays quiet and leaves the camera alone.
            """
        ),
        HelpTopic(
            symbol: "mic.fill",
            title: "Hear the camera too (optional)",
            body: """
            Want the camera's audio as a microphone? Enable the microphone during \
            setup. It installs a small audio component and needs a one-time approval in \
            System Settings. Then choose **LemurCam Microphone** as your input. Turning \
            the mic on or off never interrupts a running video feed.
            """
        ),
        HelpTopic(
            symbol: "slider.horizontal.3",
            title: "Tune the picture",
            body: """
            Resolution and frame rate live in **Settings ▸ General**. Because the \
            virtual camera locks its format when it starts, a change takes effect after \
            you restart LemurCam.
            """
        ),
        HelpTopic(
            symbol: "wrench.and.screwdriver.fill",
            title: "If something looks off",
            body: """
            **Camera missing in other apps?** Confirm it's approved in System Settings, \
            then restart LemurCam and the other app.

            **Black or frozen video?** Double-check the camera's URL and credentials, \
            and that your Mac can reach it on the network.

            **Asked about local network access?** Allow it — ONVIF discovery and many \
            cameras live on your local network.
            """
        )
    ]
}

/// One help topic: an SF Symbol, a heading, and a short Markdown body.
private struct HelpTopic: Identifiable {
    let symbol: String
    let title: String
    let body: String
    var id: String { title }
}

private struct HelpTopicCard: View {
    let topic: HelpTopic

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: topic.symbol)
                .font(.title3)
                .foregroundStyle(.tint)
                .frame(width: 24)
                .padding(.top, 1)
            VStack(alignment: .leading, spacing: 4) {
                Text(topic.title)
                    .font(.headline)
                Text(markdown(topic.body))
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    /// Render the body as Markdown, preserving the blank-line paragraph breaks in
    /// the troubleshooting topic (full Markdown parsing collapses them).
    private func markdown(_ text: String) -> AttributedString {
        let options = AttributedString.MarkdownParsingOptions(
            interpretedSyntax: .inlineOnlyPreservingWhitespace
        )
        return (try? AttributedString(markdown: text, options: options))
            ?? AttributedString(text)
    }
}
