import CoreGraphics

/// Fixed zone heights for the non-scrolling Home dashboard. The bobble is a fixed
/// 130pt circle, so the header is constant; the chart gets the remainder. Tai has
/// no permanent nav bar on Home — warnings render above the dashboard only while
/// active, shrinking the chart for their duration.
enum HomeLayout {
    /// Zone B: air above the header; sized so an up-pointing trend arrow clears
    /// the status bar.
    static let headerTopPadding: CGFloat = 12
    /// Zone B: left info panel / glucose bobble / loop status header.
    static let headerHeight: CGFloat = 150
    /// Zone C: horizontal pump panel slot; the row centers inside it.
    static let mealSlotHeight: CGFloat = 48
    /// Pull distance that triggers the forced loop.
    static let refreshTriggerDistance: CGFloat = 70
    /// Indicator row height while the loop runs.
    static let refreshIndicatorHeight: CGFloat = 40
    /// Zone E: rounded panel shared by the adjustment and bolus views.
    static let bottomPanelHeight: CGFloat = 60
    /// Zone E: horizontal inset of the panel.
    static let bottomPanelHorizontalPadding: CGFloat = 10
    /// Zone E: air above the panel.
    static let bottomZoneTopPadding: CGFloat = 10
    /// Zone E: air between panel and tab bar.
    static let bottomZoneBottomPadding: CGFloat = 16
    /// Zone E: total height including padding.
    static var bottomZoneHeight: CGFloat { bottomPanelHeight + bottomZoneTopPadding + bottomZoneBottomPadding }
    /// Zone D: breathing room above and below the chart's pane stack.
    static let chartVerticalPadding: CGFloat = 8
    /// Zone D: chart floor; must stay below the natural SE-class allocation.
    static let chartMinHeight: CGFloat = 240
    /// Height of the safety-notifications warning banner shown above the dashboard.
    static let warningBannerHeight: CGFloat = 64
}
