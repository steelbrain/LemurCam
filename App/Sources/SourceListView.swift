import SwiftUI

internal struct SourceListView: View {
    @Bindable var sourceManager: SourceManager
    @State private var showingAddSheet = false
    @State private var showingDiscoverySheet = false
    @State private var editingSource: CameraSource?
    @State private var sourceToDelete: CameraSource?

    var body: some View {
        Group {
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
        .sheet(item: $editingSource) { source in
            SourceFormView(sourceManager: sourceManager, editing: source)
        }
        .alert("Delete Camera", isPresented: Binding(
            get: { sourceToDelete != nil },
            set: { if !$0 { sourceToDelete = nil } }
        )) {
            Button("Cancel", role: .cancel) { sourceToDelete = nil }
            Button("Delete", role: .destructive) {
                if let source = sourceToDelete {
                    sourceManager.removeSource(id: source.id)
                    sourceToDelete = nil
                }
            }
        } message: {
            if let source = sourceToDelete {
                Text("Are you sure you want to delete \"\(source.name)\"?")
            }
        }
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
                            Button("Delete", role: .destructive) {
                                sourceToDelete = source
                            }
                        }
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
                    editingSource = source
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

    private func sourceSubtitle(_ source: CameraSource) -> String {
        switch source.sourceType {
        case .rtsp(let info):
            return info.url
        case .onvif(let info):
            return "\(info.host):\(info.port)"
        }
    }

    private func statusBadge(_ status: ConnectionStatus) -> some View {
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
