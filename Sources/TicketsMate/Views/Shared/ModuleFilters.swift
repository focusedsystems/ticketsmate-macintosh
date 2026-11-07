import SwiftUI
import TicketsMateCore

// MARK: - Deep-linked filters

/// A dashboard widget's handoff: open `tab` with `category` filtered to
/// `value`. `category` is the destination's FilterCategory rawValue.
struct ModuleFilterLink: Equatable {
    let tab: AppTab
    let category: String
    let value: String
}

/// Match a deep-linked value against the category's actual values, tolerating
/// case/punctuation drift ("Non-Compliant" label vs "Noncompliant" value).
func resolveFilterValue(_ incoming: String, in available: [String]?) -> String {
    let norm: (String) -> String = { $0.lowercased().filter { $0.isLetter || $0.isNumber } }
    return available?.first { norm($0) == norm(incoming) } ?? incoming
}

// MARK: - Ticket Filters

enum TicketFilterCategory: String, FilterCategoryProtocol {
    case status = "Status"
    case priority = "Priority"
    case group = "Group"
    case responsible = "Responsible"
    case age = "Age"
    case sla = "SLA"
    case form = "Form"
    case classification = "Classification"
    case type = "Type"
    case timePeriod = "Time Period"
    var id: String { rawValue }
}

extension FilterState where Category == TicketFilterCategory {
    func buildFromTickets(_ tickets: [TdxTicket]) {
        func extract(_ keyPath: (TdxTicket) -> String?) -> [String] {
            Array(Set(tickets.compactMap(keyPath).filter { !$0.isEmpty })).sorted()
        }
        availableValues[.status] = extract { $0.statusName }
        availableValues[.priority] = extract { $0.priorityName }
        var groups = extract { $0.responsibleGroupName }
        if tickets.contains(where: { $0.responsibleGroupName?.isEmpty != false }) {
            groups.append("Unassigned")
        }
        availableValues[.group] = groups
        availableValues[.sla] = ["Violated", "Within SLA"]
        // Unassigned is a real state to filter on, not the absence of one —
        // it's how you find the tickets nobody has picked up yet.
        var responsibles = extract { $0.responsibleFullName }
        if tickets.contains(where: { $0.responsibleFullName?.isEmpty != false }) {
            responsibles.append("Unassigned")
        }
        availableValues[.responsible] = responsibles
        let ages = Set(tickets.map(TicketStats.ageBucket(for:)))
        availableValues[.age] = TicketStats.ageBuckets.map(\.label).filter(ages.contains)
        availableValues[.form] = extract { $0.formName }
        availableValues[.classification] = extract { $0.classificationName }
        availableValues[.type] = extract { $0.typeName }
        availableValues[.timePeriod] = ["This Term", "Last Term", "Today", "This Week", "This Month", "Include Closed"]
    }

    func matches(_ ticket: TdxTicket) -> Bool {
        matches(ticket, ignoring: nil)
    }

    /// Matches every selection except `ignored`'s, so a widget can count the
    /// values of its own category with the other filters applied and its own
    /// values can still be added to.
    func matches(_ ticket: TdxTicket, ignoring ignored: TicketFilterCategory?) -> Bool {
        for (category, selected) in selectedValues where !selected.isEmpty && category != ignored {
            let value: String?
            switch category {
            case .status:         value = ticket.statusName
            case .priority:       value = ticket.priorityName
            case .group:
                value = ticket.responsibleGroupName?.isEmpty == false
                    ? ticket.responsibleGroupName : "Unassigned"
            case .sla:            value = ticket.slaViolated == true ? "Violated" : "Within SLA"
            case .responsible:
                value = ticket.responsibleFullName?.isEmpty == false
                    ? ticket.responsibleFullName : "Unassigned"
            case .age:            value = TicketStats.ageBucket(for: ticket)
            case .form:           value = ticket.formName
            case .classification: value = ticket.classificationName
            case .type:           value = ticket.typeName
            case .timePeriod:     continue // handled externally by date range logic
            }
            if let v = value, !selected.contains(v) { return false }
            if value == nil { return false }
        }
        return true
    }
}

