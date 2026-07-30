import Foundation
import SwiftUI

enum Adjustments {
    enum Config {}

    enum Tab: String, Hashable, Identifiable, CaseIterable {
        case overrides
        case tempTargets
        case profiles

        var id: String { rawValue }

        var name: String {
            switch self {
            case .overrides:
                return String(localized: "Overrides", comment: "Selected Tab")
            case .tempTargets:
                return String(localized: "TTs", comment: "Selected Tab — short for Temp Targets")
            case .profiles:
                return String(localized: "Profiles", comment: "Selected Tab")
            }
        }
    }

    /// UserDefaults key used by Home's cards and indicators to request a specific tab
    /// (stored as `Tab.rawValue`) on next appearance of `AdjustmentsRootView`. Home can't
    /// reach the local `@State` of the not-yet-mounted Adjustments view, so it leaves a
    /// flag for the view to consume on appear.
    static let pendingTabKey = "Adjustments.pendingTab"
}

protocol AdjustmentsProvider: Provider {}
