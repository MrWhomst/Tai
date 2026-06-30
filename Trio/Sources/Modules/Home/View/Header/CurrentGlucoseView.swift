import CoreData
import LoopKit
import SwiftUI

struct CurrentGlucoseView: View {
    let concentration: Decimal
    let hideInsulinBadge: Bool
    let timerDate: Date
    let units: GlucoseUnits
    let alarm: GlucoseAlarm?
    let lowGlucose: Decimal
    let highGlucose: Decimal
    let cgmAvailable: Bool
    var currentGlucoseTarget: Decimal
    let glucoseColorScheme: GlucoseColorScheme
    let glucose: [GlucoseStored] // This contains the last two glucose values, no matter if its manual or a cgm reading

    /// Drives the outer ring.
    var cgmProgress: DeviceLifecycleProgress?
    /// CGM status highlight, rendered verbatim.
    var cgmStatus: CgmDisplayState?
    /// Sensor expiration — fallback tag when `cgmStatus` is nil.
    var cgmSensorExpiresAt: Date?
    /// Wall-clock end of the warmup window. Drives the warmup countdown tag.
    var cgmWarmupEndsAt: Date?

    @State private var rotationDegrees: Double = 0.0

    @Environment(\.colorScheme) var colorScheme

    private var deltaFormatter: NumberFormatter {
        let formatter = NumberFormatter()
        formatter.numberStyle = .decimal
        if units == .mmolL {
            formatter.maximumFractionDigits = 1
            formatter.minimumFractionDigits = 1
            formatter.roundingMode = .halfUp
        } else {
            formatter.maximumFractionDigits = 0
        }
        formatter.positivePrefix = "  +"
        formatter.negativePrefix = "  -"
        return formatter
    }

    var body: some View {
        let triangleColor = Color(red: 0.262745098, green: 0.7333333333, blue: 0.9137254902)

        if cgmAvailable {
            if let stale = stalenessState {
                // Compact error/transition state — same styles as the
                // empty-state "Add CGM" layout below, just colored by tier.
                VStack(alignment: .center, spacing: 12) {
                    HStack {
                        Image(systemName: stale.imageName)
                            .font(.body)
                            .imageScale(.large)
                            .foregroundStyle(stale.color)
                    }
                    HStack {
                        Text(stale.label)
                            .font(.caption).bold()
                            .foregroundStyle(stale.color)
                    }
                }.frame(alignment: .top)
            } else {
                // Bobble renders at 0.9 to leave breathing room for the right
                // panel + pump view siblings; the compact and empty-state
                // branches above and below already fit at 1.0.
                bobbleAndTag(triangleColor: triangleColor)
                    .scaleEffect(0.9)
            }
        } else {
            VStack(alignment: .center, spacing: 12) {
                HStack
                    {
                        // no cgm defined so display a generic CGM
                        Image(systemName: "sensor.tag.radiowaves.forward.fill").font(.body).imageScale(.large)
                    }
                HStack {
                    Text("Add CGM").font(.caption).bold()
                }
            }.frame(alignment: .top)
        }
    }

    @ViewBuilder private func bobbleAndTag(triangleColor: Color) -> some View {
        // Push the U-concentration badge outside the lifecycle arc (radius 73)
        // when it's drawn; collapse to the bobble edge otherwise. The sensor
        // icon mirrors the badge across BOTH axes so it lands in the truly
        // opposite corner — badge at 7-8 o'clock, icon at 1-2 o'clock.
        let arcVisible = cgmProgress != nil && shouldShowArc
        let badgeOffsetX: CGFloat = arcVisible ? -72 : -65
        let badgeOffsetY: CGFloat = arcVisible ? 72 : 65

        ZStack {
            if let progress = cgmProgress, shouldShowArc {
                SensorLifecycleArcView(
                    progress: progress.percentComplete,
                    progressState: progress.progressState
                )
            }

            TrendShape(gradient: TaiStyle.ringGradient(), color: triangleColor, showArrow: true)
                .rotationEffect(.degrees(rotationDegrees))

            InsulinConcentrationBadge(concentration: concentration, hide: hideInsulinBadge)
                .offset(x: badgeOffsetX, y: badgeOffsetY)

            VStack(alignment: .center) {
                bobbleContent()
            }
        }
        .overlay {
            // Icon-only — text doesn't fit in the bobble corner. Hourglass
            // variant tracks lifecycle position (sand at bottom = fresh,
            // sand at top = expiring); palette renders Tai colors with a
            // severity-driven outline. Hidden when the trend arrow swings
            // into the icon's top-right corner (fortyFiveUp → arrow at
            // ~1-2 o'clock).
            if let symbol = sensorLifecycleSymbol, !trendCollidesWithTag {
                Image(systemName: symbol)
                    .font(.title3)
                    .symbolRenderingMode(.palette)
                    .foregroundStyle(
                        sensorLifecycleOutlineColor,
                        sensorLifecycleSandColor,
                        sensorLifecycleSandColor
                    )
                    .offset(x: -badgeOffsetX, y: -badgeOffsetY)
                    .zIndex(1)
            }
        }
        .onChange(of: glucose.last?.directionEnum) {
            withAnimation {
                switch glucose.last?.directionEnum {
                case .doubleUp,
                     .singleUp,
                     .tripleUp:
                    rotationDegrees = -90
                case .fortyFiveUp:
                    rotationDegrees = -45
                case .flat:
                    rotationDegrees = 0
                case .fortyFiveDown:
                    rotationDegrees = 45
                case .doubleDown,
                     .singleDown,
                     .tripleDown:
                    rotationDegrees = 90
                case nil,
                     .notComputable,
                     .rateOutOfRange:
                    rotationDegrees = 0
                default:
                    rotationDegrees = 0
                }
            }
        }
    }

    private var delta: String {
        guard glucose.count >= 2 else {
            return "--"
        }

        var lastGlucose = Decimal(glucose.last?.glucose ?? 0)
        var secondLastGlucose = Decimal(glucose.first?.glucose ?? 0)
        if units == .mmolL {
            lastGlucose = lastGlucose.asMmolL
            secondLastGlucose = secondLastGlucose.asMmolL
        }
        let delta = lastGlucose - secondLastGlucose
        return deltaFormatter.string(from: delta as NSNumber) ?? "--"
    }

    @ViewBuilder private func bobbleContent() -> some View {
        HStack {
            if let glucoseValue = glucose.last?.glucose, isReadingFresh {
                let displayGlucose = units == .mgdL
                    ? Decimal(glucoseValue).description
                    : Decimal(glucoseValue).formattedAsMmolL
                Text(glucoseValue == 400 ? "HIGH" : displayGlucose)
                    .font(.system(size: 40, weight: .bold, design: .rounded))
                    .foregroundStyle(glucoseColor(for: glucoseValue))
            } else {
                Text("– –")
                    .font(.system(size: 40, weight: .bold, design: .rounded))
                    .foregroundStyle(.secondary)
            }
        }
        if isReadingFresh {
            HStack {
                let minutesAgoString = TimeAgoFormatter.minutesAgo(from: glucose.last?.date)
                Group {
                    Text(minutesAgoString)
                    Text(delta)
                }
                .font(.callout).fontWeight(.bold)
                .foregroundStyle(colorScheme == .dark ? Color.white.opacity(0.9) : Color.secondary)
            }
            .frame(alignment: .top)
        }
    }

    /// Matches `APSManager`'s loop-input freshness gate — readings older than
    /// 12 minutes (one missed CGM transmission on a 5-min schedule) get
    /// masked to dashes. Handles warmup + sensor failure naturally: no
    /// fresh data → no number on the bobble.
    private var isReadingFresh: Bool {
        guard let date = glucose.last?.date else { return false }
        return Date().timeIntervalSince(date) < 12 * 60
    }

    /// Only the `fortyFiveUp` (-45°) trend points the arrow into the icon's
    /// top-right corner; `singleUp`/`doubleUp`/`tripleUp` (-90°) swing past it
    /// to 12 o'clock and the down arrows clear it entirely.
    private var trendCollidesWithTag: Bool { rotationDegrees == -45 }

    /// Error/transition states (sensor expired, sensor failure, signal loss,
    /// stabilizing, etc.) collapse the bobble to a compact symbol-over-label
    /// view — the bobble's purpose is to show glucose, so a fresh-reading-less
    /// bobble with arc + dashes obscures rather than informs. Warmup is the
    /// exception: it's a short, expected lifecycle phase and the arc + tag
    /// countdown carry useful info, so the bobble stays.
    private var stalenessState: (imageName: String, label: String, color: Color)? {
        guard !isReadingFresh,
              !isInWarmup,
              let status = cgmStatus,
              !status.imageName.isEmpty
        else { return nil }
        let color: Color
        switch status.status {
        case .critical: color = .loopRed
        case .warning: color = .orange
        case .normal: color = .secondary
        }
        // LibreLoop/G7 split labels with "\n" for their two-line native pills;
        // collapse to spaces so the compact label reads cleanly.
        let oneLine = status.localizedMessage.replacingOccurrences(of: "\n", with: " ")
        return (status.imageName, oneLine, color)
    }

    /// Arc shown for warmup, the last 48 h of a time-based sensor (incl.
    /// grace period), or any non-normal state from a battery-based manager.
    private var shouldShowArc: Bool {
        if isInWarmup { return true }
        if let expiresAt = cgmSensorExpiresAt {
            return expiresAt.timeIntervalSinceNow <= 48 * 60 * 60
        }
        return cgmProgress?.progressState != .normalCGM
    }

    /// String sniff — loopandlearn LoopKit has no structural warmup flag.
    private var isInWarmup: Bool {
        guard let message = cgmStatus?.localizedMessage else { return false }
        let lowered = message.lowercased()
        return lowered.contains("warming up") || lowered.contains("warmup")
    }

    private var isStabilizing: Bool {
        cgmStatus?.localizedMessage.lowercased().contains("stabilizing") ?? false
    }

    /// Outline color of the lifecycle hourglass — a phase tag, not a severity
    /// tag. Warmup/stabilizing get Tai-blue (insulin); the expiry window and
    /// generic non-normal states get orange. The actual "how urgent" signal
    /// is carried by `sensorLifecycleSandColor` + the symbol variant.
    private var sensorLifecycleOutlineColor: Color {
        if isInWarmup || isStabilizing { return .insulin }
        return .orange
    }

    /// Sand-fill color tracking *where in the lifecycle* the sensor is.
    /// Warmup runs the Tai progression in reverse (purple → insulin → green)
    /// — sensor is least usable at the start, becomes ready at the end —
    /// while expiry runs it forward (green → insulin → purple) as the
    /// sensor's final 48h drain. Stabilizing pins to green (just past the
    /// finish line).
    private var sensorLifecycleSandColor: Color {
        if isStabilizing { return .loopGreen }
        if isInWarmup {
            guard let endsAt = cgmWarmupEndsAt else { return .yellow }
            let minutesRemaining = endsAt.timeIntervalSinceNow / 60
            switch minutesRemaining {
            case 60...: return .purple
            case 30 ..< 60: return .yellow
            default: return .loopGreen
            }
        }
        if let expiresAt = cgmSensorExpiresAt {
            let hoursRemaining = expiresAt.timeIntervalSinceNow / 3600
            switch hoursRemaining {
            case 24...: return .loopGreen
            case 12 ..< 24: return .insulin
            default: return .purple
            }
        }
        return .insulin
    }

    /// Hourglass variant tracking sensor lifecycle position. Real-hourglass
    /// semantics: sand starts at the top (lots of time left / fresh warmup)
    /// and drains to the bottom (nearly done / warmup almost complete).
    /// Gated to the same warmup/48h-from-expiry window as `shouldShowArc`.
    private var sensorLifecycleSymbol: String? {
        if isInWarmup {
            guard let endsAt = cgmWarmupEndsAt else { return "hourglass" }
            let minutesRemaining = endsAt.timeIntervalSinceNow / 60
            switch minutesRemaining {
            case 60...: return "hourglass.tophalf.filled"
            case 30 ..< 60: return "hourglass"
            default: return "hourglass.bottomhalf.filled"
            }
        }
        if isStabilizing { return "hourglass.bottomhalf.filled" }
        guard shouldShowArc else { return nil }
        if let expiresAt = cgmSensorExpiresAt {
            let hoursRemaining = expiresAt.timeIntervalSinceNow / 3600
            switch hoursRemaining {
            case 24...: return "hourglass.tophalf.filled"
            case 12 ..< 24: return "hourglass"
            default: return "hourglass.bottomhalf.filled"
            }
        }
        if cgmStatus != nil { return "hourglass" }
        return nil
    }

    private func glucoseColor(for glucoseValue: Int16) -> Color {
        // TODO: workaround for now: set low value to 55, to have dynamic color shades between 55 and user-set low (approx. 70); same for high glucose
        let hardCodedLow = Decimal(55)
        let hardCodedHigh = Decimal(220)
        let isDynamicColorScheme = glucoseColorScheme == .dynamicColor
        guard Decimal(glucoseValue) <= lowGlucose || Decimal(glucoseValue) >= highGlucose else {
            return Color.primary
        }
        return Trio.getDynamicGlucoseColor(
            glucoseValue: Decimal(glucoseValue),
            highGlucoseColorValue: isDynamicColorScheme ? hardCodedHigh : highGlucose,
            lowGlucoseColorValue: isDynamicColorScheme ? hardCodedLow : lowGlucose,
            targetGlucose: currentGlucoseTarget,
            glucoseColorScheme: glucoseColorScheme
        )
    }
}

struct Triangle: Shape {
    func path(in rect: CGRect) -> Path {
        var path = Path()

        path.move(to: CGPoint(x: rect.midX, y: rect.minY + 15))
        path.addLine(to: CGPoint(x: rect.maxX, y: rect.maxY))

        path.addQuadCurve(to: CGPoint(x: rect.minX, y: rect.maxY), control: CGPoint(x: rect.midX, y: rect.midY + 10))

        path.closeSubpath()

        return path
    }
}

struct TrendShape: View {
    @Environment(\.colorScheme) var colorScheme

    let gradient: AngularGradient
    let color: Color
    var showArrow: Bool = true

    var body: some View {
        HStack(alignment: .center) {
            ZStack {
                Group {
                    TriangleOffset(color: .clear)
                    CircleShape(gradient: gradient)
                    if showArrow {
                        TriangleShape(color: color)
                    }
                }.shadow(color: Color.black.opacity(colorScheme == .dark ? 0.75 : 0.33), radius: colorScheme == .dark ? 5 : 3)
                CircleShape(gradient: gradient)
            }
        }
    }
}

struct CircleShape: View {
    @Environment(\.colorScheme) var colorScheme

    let gradient: AngularGradient

    // Default to TaiStyle's gradient if none is provided
    init(gradient: AngularGradient = TaiStyle.ringGradient()) {
        self.gradient = gradient
    }

    var body: some View {
        ZStack {
            Circle()
                .stroke(gradient, lineWidth: 6)
                .background(Circle().fill(Color.chart))
                .frame(width: 130, height: 130)
        }
    }
}

struct TriangleShape: View {
    let color: Color

    var body: some View {
        Triangle()
            .fill(color)
            .frame(width: 35, height: 35)
            .rotationEffect(.degrees(90))
            .offset(x: 85)
    }
}

struct TriangleOffset: View {
    let color: Color

    var body: some View {
        Triangle()
            .fill(color)
            .frame(width: 35, height: 35)
            .rotationEffect(.degrees(-90))
            .offset(x: -85)
    }
}
