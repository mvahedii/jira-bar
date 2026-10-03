import SwiftUI

/// Icon and color for a priority, derived from its position in the project's list
/// (first = highest), so it works for any priority scheme.
enum PriorityStyle {
    static func symbol(index: Int, count: Int) -> String {
        switch bucket(index, count) {
        case 0: return "chevron.up.2"
        case 1: return "chevron.up"
        case 2: return "equal"
        case 3: return "chevron.down"
        default: return "chevron.down.2"
        }
    }

    static func color(index: Int, count: Int) -> Color {
        switch bucket(index, count) {
        case 0: return .red
        case 1: return .orange
        case 2: return .yellow
        case 3: return .blue
        default: return .teal
        }
    }

    private static func bucket(_ index: Int, _ count: Int) -> Int {
        guard count > 1 else { return 2 }
        let f = Double(index) / Double(count - 1)
        if f == 0 { return 0 }
        if f < 0.4 { return 1 }
        if f < 0.6 { return 2 }
        if f < 1 { return 3 }
        return 4
    }
}
