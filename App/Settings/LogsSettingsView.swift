import AppKit
import SwiftUI

internal struct LogsSettingsView: View {
    private let store = LogStore.shared

    var body: some View {
        VStack(spacing: 0) {
            scrollableLogContent
            Divider()
            logToolbar
            logFooter
        }
    }

    private var scrollableLogContent: some View {
        ScrollViewReader { proxy in
            ScrollView {
                Text(logAttributedString)
                    .font(.system(.caption, design: .monospaced))
                    .textSelection(.enabled)
                    .padding(8)
                    .frame(maxWidth: .infinity, alignment: .leading)

                Color.clear
                    .frame(height: 1)
                    .id("log-bottom")
            }
            .onChange(of: store.entries.count) {
                withAnimation {
                    proxy.scrollTo("log-bottom", anchor: .bottom)
                }
            }
        }
    }

    private var logToolbar: some View {
        HStack {
            Text("\(store.entries.count) entries")
                .font(.caption)
                .foregroundStyle(.secondary)
            Spacer()
            Button("Copy All") {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(formattedLog, forType: .string)
            }
            .disabled(store.entries.isEmpty)
            Button("Clear") {
                store.clear()
            }
        }
        .padding(8)
    }

    private var logFooter: some View {
        HStack {
            Text("Extension logs are visible in Console.app (filter by \"cam.lemur.app.extension\").")
                .font(.caption2)
                .foregroundStyle(.tertiary)
            Spacer()
        }
        .padding(.horizontal, 8)
        .padding(.bottom, 4)
    }

    private var logAttributedString: AttributedString {
        var result = AttributedString()
        for (index, entry) in store.entries.enumerated() {
            let ts = entry.date.formatted(
                .dateTime.hour().minute().second().secondFraction(.fractional(3))
            )
            let cat = entry.category.padding(toLength: 5, withPad: " ", startingAt: 0)
            let lvl = entry.level.padding(toLength: 5, withPad: " ", startingAt: 0)
            let line = "\(ts)  \(cat)  \(lvl)  \(entry.message)"

            var segment = AttributedString(line)
            segment.foregroundColor = levelColor(entry.level)
            result.append(segment)

            if index < store.entries.count - 1 {
                result.append(AttributedString("\n"))
            }
        }
        return result
    }

    private var formattedLog: String {
        store.entries.map { entry in
            let ts = entry.date.formatted(.dateTime.hour().minute().second().secondFraction(.fractional(3)))
            return "[\(entry.category)] \(entry.level): \(ts) \(entry.message)"
        }
        .joined(separator: "\n")
    }

    private func levelColor(_ level: String) -> Color {
        switch level {
        case "ERROR", "FAULT":
            return .red
        case "WARN":
            return .yellow
        default:
            return .primary
        }
    }
}
