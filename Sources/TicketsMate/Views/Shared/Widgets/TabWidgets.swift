import SwiftUI
import TicketsMateCore

// Each tab's Widgets row. The cards are the ones the Dashboard used to carry,
// moved next to the list they summarise; a click filters that list in place.

// MARK: - Tickets

struct TicketsWidgetsSection: View {
    /// The tickets the list would show with every filter applied except the
    /// given category's (nil: every filter). Each breakdown counts with its
    /// own category left out, so its other values stay on screen and can be
    /// added to the selection — clicking widgets mixes and matches filters.
    let tickets: (TicketFilterCategory?) -> [TdxTicket]
    /// The list's own filters: every widget reads and changes them, so the
    /// filter panel, the list and the widgets always agree.
    let filters: FilterState<TicketFilterCategory>
    var isLoading = false

    private var selected: [TicketFilterCategory: Set<String>] { filters.selectedValues }

    var body: some View {
        let shown = tickets(nil)
        let stats = TicketStats(tickets: shown)
        WidgetsSection(tab: .tickets, equalHeights: true, singleRow: true) {
            WidgetKPIGrid(loading: isLoading && shown.isEmpty, tiles: kpiTiles(openStatuses: openStatuses))

            let byStatus = TicketStats(tickets: tickets(.status)).byStatus
            WidgetCard(title: "By Status", isLoading: isLoading) {
                if byStatus.isEmpty {
                    emptyState
                } else {
                    DonutWidget(slices: byStatus.map {
                        ChartSlice(label: $0.label, value: $0.value,
                                   color: shade(ticketStatusColor($0.label), $0.label, in: .status))
                    }, size: 110, adaptsToWidth: true) { toggle(.status, $0) }
                }
            }

            barCard("By Priority", TicketStats(tickets: tickets(.priority)).byPriority, category: .priority) {
                ticketPriorityColor($0)
            }
            barCard("By Age", TicketStats(tickets: tickets(.age)).byAge, category: .age) { ticketAgeColor($0) }
            barCard("By Responsible", TicketStats(tickets: tickets(.responsible)).byResponsible, category: .responsible) {
                $0 == TicketStats.unassigned ? .gray : .teal
            }
            barCard("By Group", TicketStats(tickets: tickets(.group)).byGroup, category: .group) {
                $0 == TicketStats.unassigned ? .gray : .indigo
            }
        }
    }

    @ViewBuilder
    private var emptyState: some View {
        if isLoading { SkeletonChartCard() } else { WidgetEmptyState("No tickets match") }
    }

    /// Values outside an active selection fade, so the chart shows what is
    /// picked and what else could be.
    private func shade(_ color: Color, _ label: String, in category: TicketFilterCategory?) -> Color {
        guard let category, let picked = selected[category], !picked.isEmpty else { return color }
        return picked.contains(label) ? color : color.opacity(0.3)
    }

    private func barCard(_ title: String, _ counts: [TicketStats.Count], category: TicketFilterCategory?,
                         color: @escaping (String) -> Color) -> some View {
        WidgetCard(title: title, isLoading: isLoading) {
            if counts.isEmpty {
                emptyState
            } else {
                HorizontalBarList(
                    bars: counts.map {
                        ChartBar(label: $0.label, value: $0.value, color: shade(color($0.label), $0.label, in: category))
                    },
                    compact: true,
                    onSelect: category.map { category in { label in toggle(category, label) } }
                )
            }
        }
    }

    private func toggle(_ category: TicketFilterCategory, _ label: String) {
        filters.toggle(value: label, in: category)
    }

    /// Statuses that count as open (everything shown but On Hold), for the
    /// Open tile.
    private var openStatuses: Set<String> {
        Set(TicketStats(tickets: tickets(.status)).byStatus.map(\.label)).subtracting([Self.onHold])
    }

    private static let onHold = "On Hold"

    /// The figures double as filters: each tile toggles the selection it
    /// counts, and lights up while that selection is on.
    private func kpiTiles(openStatuses: Set<String>) -> [TicketKPITile] {
        func single(_ category: TicketFilterCategory, _ value: String) -> (Bool, () -> Void) {
            (selected[category]?.contains(value) ?? false, { toggle(category, value) })
        }
        let openOn = !openStatuses.isEmpty && selected[.status] == openStatuses
        let onHold = single(.status, Self.onHold)
        let unassigned = single(.responsible, TicketStats.unassigned)
        let sla = single(.sla, "Violated")
        let aging = single(.age, TicketStats.ageBuckets.last!.label)
        return [
            TicketKPITile(title: "Showing", value: TicketStats(tickets: tickets(nil)).total, icon: "list.bullet",
                          color: .secondary, isOn: false, help: "Clear every filter") { filters.clearAll() },
            TicketKPITile(title: "Open", value: TicketStats(tickets: tickets(nil)).open, icon: "ticket",
                          color: .purple, isOn: openOn, help: "Show open tickets") {
                filters.selectedValues[.status] = openOn ? [] : openStatuses
            },
            TicketKPITile(title: "On Hold", value: TicketStats(tickets: tickets(nil)).onHold, icon: "pause.circle",
                          color: .yellow, isOn: onHold.0, help: "Show tickets on hold", action: onHold.1),
            TicketKPITile(title: "Unassigned", value: TicketStats(tickets: tickets(nil)).unassigned,
                          icon: "person.crop.circle.badge.questionmark", color: .teal, isOn: unassigned.0,
                          help: "Show tickets nobody is responsible for", action: unassigned.1),
            TicketKPITile(title: "SLA Violated", value: TicketStats(tickets: tickets(nil)).slaViolated,
                          icon: "clock.badge.exclamationmark", color: .orange, isOn: sla.0,
                          help: "Show tickets past their SLA", action: sla.1),
            TicketKPITile(title: "Over \(TicketStats.agingDays) days", value: TicketStats(tickets: tickets(nil)).aging,
                          icon: "hourglass", color: .indigo, isOn: aging.0,
                          help: "Show tickets older than \(TicketStats.agingDays) days", action: aging.1),
        ]
    }
}

struct TicketKPITile {
    let title: String
    let value: Int
    let icon: String
    let color: Color
    let isOn: Bool
    let help: String
    let action: () -> Void
}

/// Figures as a grid of buttons in one cell of the strip. At narrower widths
/// the tiles take fewer columns and more rows; the grid always fills the
/// height the row offers, so it ends level with the cards beside it. Text
/// never shrinks below the caption size.
struct WidgetKPIGrid: View {
    let loading: Bool
    let tiles: [TicketKPITile]
    /// The most columns to try, widest first.
    var maxColumns = 3

    var body: some View {
        ViewThatFits(in: .horizontal) {
            ForEach(Array(stride(from: maxColumns, through: 2, by: -1)), id: \.self) { columns in
                grid(columns: columns).frame(minWidth: CGFloat(columns) * 110)
            }
            grid(columns: 2)
        }
        .frame(maxHeight: .infinity)
    }

    private func grid(columns: Int) -> some View {
        let rows = Int((Double(tiles.count) / Double(columns)).rounded(.up))
        return Grid(horizontalSpacing: 6, verticalSpacing: 6) {
            ForEach(0..<rows, id: \.self) { row in
                GridRow {
                    ForEach(0..<columns, id: \.self) { col in
                        let index = row * columns + col
                        if index < tiles.count {
                            tile(tiles[index])
                        } else {
                            Color.clear.gridCellUnsizedAxes([.horizontal, .vertical])
                        }
                    }
                }
            }
        }
    }

    private func tile(_ t: TicketKPITile) -> some View {
        Button(action: t.action) {
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 5) {
                    Image(systemName: t.icon).appFont(.caption).foregroundStyle(t.color)
                    if loading {
                        SkeletonView(width: 30, height: 16, cornerRadius: 4)
                    } else {
                        Text(t.value, format: .number).appFont(.title3, weight: .bold)
                            .monospacedDigit().lineLimit(1)
                    }
                    Spacer(minLength: 0)
                }
                Text(t.title).appFont(.caption).foregroundStyle(.secondary)
                    .lineLimit(1).truncationMode(.tail)
            }
            .padding(.horizontal, 7)
            .padding(.vertical, 6)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
            .background(t.isOn ? Color.accentColor.opacity(0.14) : Color.secondary.opacity(0.06),
                        in: RoundedRectangle(cornerRadius: 10))
            .overlay(RoundedRectangle(cornerRadius: 10)
                .stroke(t.isOn ? Color.accentColor : Color.secondary.opacity(0.15), lineWidth: t.isOn ? 1.5 : 1))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(t.help)
        .accessibilityLabel("\(t.title): \(t.value)")
        .accessibilityAddTraits(t.isOn ? .isSelected : [])
        .accessibilityHint(t.help)
    }
}

/// Status colours shared by the board columns and the status donut. No red.
func ticketStatusColor(_ name: String) -> Color {
    let n = name.lowercased()
    if n.contains("new") || n.contains("open") { return .blue }
    if n.contains("progress") { return .orange }
    if n.contains("hold") || n.contains("pending") || n.contains("waiting") { return .yellow }
    if n.contains("resolved") || n.contains("completed") { return .green }
    if n.contains("closed") { return .gray }
    if n.contains("cancel") { return .orange }
    return .secondary
}

/// Keyed by name so a missing priority never shifts the others' colours. No
/// red: High is orange.
func ticketPriorityColor(_ name: String) -> Color {
    ["Low": .green, "Medium": .blue, "High": .orange, "Emergency": .purple][name] ?? .gray
}

func ticketAgeColor(_ bucket: String) -> Color {
    ["Today": .green, "1–7 days": .blue, "8–30 days": .orange, "Over 30 days": .purple][bucket] ?? .gray
}

// MARK: - Projects


/// A card with nothing to chart: one centred line in the card's own height,
/// rather than two zero figures over a lone "none" message.
struct WidgetAllClear: View {
    let title: String
    let detail: String

    var body: some View {
        VStack(spacing: 4) {
            Image(systemName: "checkmark.circle")
                .appFont(.title2)
                .foregroundStyle(.green)
                .accessibilityHidden(true)
            Text(title).appFont(.callout, weight: .medium)
            Text(detail).appFont(.caption).foregroundStyle(.secondary).monospacedDigit()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(.vertical, 8)
        .accessibilityElement(children: .combine)
    }
}

struct WidgetMiniStat: View {
    let label: String
    let value: String
    let color: Color

    var body: some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(value).appFont(.title3, weight: .bold).monospacedDigit().foregroundStyle(color)
            Text(label).appFont(.caption).foregroundStyle(.secondary)
        }
    }
}
