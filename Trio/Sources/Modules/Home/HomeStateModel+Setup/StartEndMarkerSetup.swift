import Foundation

extension Home.StateModel {
    /// Leading edge of the chart-feeding fetch window.
    var chartHistoryStartDate: Date {
        Date(timeIntervalSinceNow: -chartHistorySpan)
    }

    /// One-shot: widens the fetch window to the full history span and
    /// re-runs the chart array fetches. Chart-only; dosing reads its own
    /// storage fetches and is unaffected.
    func expandChartHistory() {
        guard !isChartHistoryExpanded else { return }
        isChartHistoryExpanded = true
        chartHistorySpan = MainChartHelper.Config.maxChartHistorySeconds
        updateStartEndMarkers()
        setupGlucoseArray()
        setupCarbsArray()
        setupFPUsArray()
        setupInsulinArray()
        setupDeterminationsArray()
        setupOverrideRunStored()
        setupTempTargetsStored()
        setupTempTargetsRunStored()
        Task { await setupGlucoseTargets() }
    }

    // Update start and  end marker to fix scroll update problem with x axis
    func updateStartEndMarkers() {
        startMarker = Date(timeIntervalSinceNow: -chartHistorySpan)

        let threeHourSinceNow = Date(timeIntervalSinceNow: TimeInterval(hours: 3))

        // min is 1.5h -> (1.5*1h = 1.5*(5*12*60))
        let dynamicFutureDateForCone = Date(timeIntervalSinceNow: TimeInterval(
            Int(1.5) * 5 * minCount * 60
        ))

        endMarker = forecastDisplayType == .lines ? threeHourSinceNow : dynamicFutureDateForCone <= threeHourSinceNow ?
            dynamicFutureDateForCone.addingTimeInterval(TimeInterval(minutes: 30)) : threeHourSinceNow
    }
}
