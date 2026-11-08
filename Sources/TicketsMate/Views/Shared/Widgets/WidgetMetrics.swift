import SwiftUI
import TicketsMateCore

// MARK: - Data Models

struct ChartSlice: Identifiable {
    let id = UUID()
    let label: String
    let value: Int
    let color: Color
}

struct ChartBar: Identifiable {
    let id = UUID()
    let label: String
    let value: Int
    let color: Color
}

struct KPI: Identifiable {
    let id = UUID()
    let title: String
    let value: String
    let icon: String
    let color: Color
    let loading: Bool
    let tab: AppTab
}

