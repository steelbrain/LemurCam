import SwiftUI

internal struct SourceListView: View {
    @Bindable var sourceManager: SourceManager
    @State private var showingAddSheet = false
    @State private var showingDiscoverySheet = false
    @State private var editingSource: CameraSource?
    @State private var sourceToDelete: CameraSource?
    @State private var removeError: String?
    /// What an edit saved with a problem (`SourceFormSaveOutcome.savedWithProblem`)
    /// must tell the user, held until its form has closed.
    @State private var pendingEditProblem: String?
    /// The same, shown over the list once the form is gone.
    @State private var editProblem: String?

    /// While saving is refused, cameras can't be added, edited or removed (the banner
    /// says why), so the actions that would are disabled.
    private var changesRefused: Bool { sourceManager.saveRefusal != nil }

    var body: some View {
        VStack(spacing: 0) {
            if let message = sourceManager.saveProblemMessage {
                SaveRefusalBanner(message: message)
                Divider()
            }
            if sourceManager.sources.isEmpty {
                emptyState
            } else {
                sourceList
            }
        }
        .sheet(isPresented: $showingAddSheet) {
            SourceFormView(sourceManager: sourceManager)
        }
        .sheet(isPresented: $showingDiscoverySheet) {
            DiscoveryView(sourceManager: sourceManager)
        }
        .sheet(item: $editingSource, onDismiss: showPendingEditProblem) { source in
            SourceFormView(sourceManager: sourceManager, editing: source) { pendingEditProblem = $0 }
        }
        .alert("Delete Camera", isPresented: Binding(
            get: { sourceToDelete != nil },
            set: { if !$0 { sourceToDelete = nil } }
        )) {
            Button("Cancel", role: .cancel) { sourceToDelete = nil }
            Button("Delete", role: .destructive) {
                if let source = sourceToDelete {
                    do {
                        try sourceManager.removeSource(id: source.id)
                    } catch {
                        removeError = error.localizedDescription
                    }
                    sourceToDelete = nil
                }
            }
        } message: {
            if let source = sourceToDelete {
                Text("Are you sure you want to delete \"\(source.name)\"?")
            }
        }
        .alert("Camera Not Deleted", isPresented: Binding(
            get: { removeError != nil },
            set: { if !$0 { removeError = nil } }
        )) {
            Button("OK") { removeError = nil }
        } message: {
            Text(removeError ?? "")
        }
        .alert("Login Not Saved", isPresented: Binding(
            get: { editProblem != nil },
            set: { if !$0 { editProblem = nil } }
        )) {
            Button("OK") { editProblem = nil }
        } message: {
            Text(editProblem ?? "")
        }
    }

    /// The edit form closed: show what its save left to do, now that no sheet is up.
    private func showPendingEditProblem() {
        editProblem = pendingEditProblem
        pendingEditProblem = nil
    }

    private var emptyState: some View {
        VStack(spacing: 16) {
            Image(systemName: "video.slash")
                .font(.system(size: 48))
                .foregroundStyle(.secondary)
            Text("No Cameras Configured")
                .font(.title2)
            Text("Add an RTSP or ONVIF camera to get started.")
                .font(.subheadline)
                .foregroundStyle(.secondary)
            HStack(spacing: 12) {
                Button("Discover Cameras") {
                    showingDiscoverySheet = true
                }
                .controlSize(.large)

                Button("Add Manually") {
                    showingAddSheet = true
                }
                .controlSize(.large)
            }
            .disabled(changesRefused)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var sourceList: some View {
        VStack(spacing: 0) {
            activeCameraPicker
                .padding(8)
            Divider()

            List {
                ForEach(sourceManager.sources) { source in
                    sourceRow(source)
                        .contextMenu {
                            Button("Edit") { editingSource = source }
                                .disabled(changesRefused)
                            Button("Delete", role: .destructive) {
                                sourceToDelete = source
                            }
                            .disabled(changesRefused)
                        }
                        .moveDisabled(changesRefused)
                }
                .onMove { from, to in
                    sourceManager.moveSource(from: from, to: to)
                }
            }

            Divider()

            HStack {
                Button {
                    showingDiscoverySheet = true
                } label: {
                    Image(systemName: "antenna.radiowaves.left.and.right")
                }
                .help("Discover Cameras")

                Button {
                    showingAddSheet = true
                } label: {
                    Image(systemName: "plus")
                }

                Spacer()
            }
            .disabled(changesRefused)
            .padding(8)
        }
    }

    private var activeCameraPicker: some View {
        Picker("Active Camera", selection: Binding(
            get: { sourceManager.activeSourceID },
            set: { sourceManager.setActiveSource(id: $0) }
        )) {
            Text("None").tag(nil as UUID?)
            ForEach(sourceManager.sources) { source in
                Text(source.name).tag(source.id as UUID?)
            }
        }
    }

    private func sourceRow(_ source: CameraSource) -> some View {
        HStack {
            sourceRowInfo(source)
            Spacer()
            statusBadge(sourceManager.connectionStatuses[source.id] ?? .disconnected)
            activeBadge(source)
        }
        .padding(.vertical, 4)
        .contentShape(Rectangle())
        .gesture(
            ExclusiveGesture(
                TapGesture(count: 2),
                TapGesture()
            )
            .onEnded { gesture in
                switch gesture {
                case .first:
                    if !changesRefused { editingSource = source }
                case .second:
                    sourceManager.setActiveSource(id: source.id)
                }
            }
        )
    }

    private func sourceRowInfo(_ source: CameraSource) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(source.name)
                .fontWeight(source.id == sourceManager.activeSourceID ? .semibold : .regular)
            Text(sourceSubtitle(source))
                .font(.caption)
                .foregroundStyle(.secondary)
            if let errorMessage = sourceManager.errorMessages[source.id] {
                Text(errorMessage)
                    .font(.caption2)
                    .foregroundStyle(.red)
                    .lineLimit(2)
            }
        }
    }

    @ViewBuilder
    private func activeBadge(_ source: CameraSource) -> some View {
        if source.id == sourceManager.activeSourceID {
            Text("Active")
                .font(.caption2)
                .fontWeight(.medium)
                .padding(.horizontal, 6)
                .padding(.vertical, 2)
                .background(.blue.opacity(0.15))
                .foregroundStyle(.blue)
                .clipShape(Capsule())
        }
    }
}

private extension SourceListView {
    func sourceSubtitle(_ source: CameraSource) -> String {
        switch source.sourceType {
        case .rtsp(let info):
            return DisplayedURL.redacted(info.url)
        case .onvif(let info):
            return "\(info.host):\(info.port)"
        }
    }

    func statusBadge(_ status: ConnectionStatus) -> some View {
        HStack(spacing: 4) {
            Circle()
                .fill(connectionStatusColor(status))
                .frame(width: 8, height: 8)
            Text(connectionStatusLabel(status))
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
    }
}

/// Shown above the camera list while cameras aren't being saved: for the whole
/// session when saved cameras couldn't be read, or until a save works after one failed.
private struct SaveRefusalBanner: View {
    let message: String

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(.orange)
            Text(message)
                .font(.callout)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(Color.orange.opacity(0.12))
    }
}
