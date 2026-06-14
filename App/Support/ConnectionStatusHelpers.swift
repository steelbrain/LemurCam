import SwiftUI

internal func connectionStatusColor(_ status: ConnectionStatus) -> Color {
    switch status {
    case .pending: .gray
    case .connecting: .orange
    case .connected: .green
    case .disconnected: .red
    case .reconnecting: .orange
    case .error: .red
    }
}

internal func connectionStatusLabel(_ status: ConnectionStatus) -> String {
    switch status {
    case .pending: "Pending"
    case .connecting: "Connecting"
    case .connected: "Connected"
    case .disconnected: "Disconnected"
    case .reconnecting: "Reconnecting…"
    case .error: "Error"
    }
}
