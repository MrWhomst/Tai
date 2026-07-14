import CoreData
import Foundation

extension Home.StateModel {
    @MainActor func setupGlucoseController() {
        glucoseControllerDelegate.onContentChange = { [weak self] in
            Task { @MainActor in
                self?.updateGlucoseFromController()
            }
        }

        do {
            try glucoseController.performFetch()
            updateGlucoseFromController()
        } catch {
            debug(.default, "\(DebuggingIdentifiers.failed) Failed to perform glucose fetch: \(error)")
        }
    }

    @MainActor func updateGlucoseFromController() {
        guard let objects = glucoseController.fetchedObjects else { return }
        glucoseFromPersistence = objects
        latestTwoGlucoseValues = Array(objects.suffix(2))
        updateGlucoseChartYAxis(glucoseValues: objects)
        updateGlucosePeaks()
    }

    /// Re-picks the glucose turning points for the current data and zoom. The picker
    /// window scales with the committed pinch-zoom span (`chartVisibleHours / 4`), the
    /// same ratio the old time-range buttons used.
    func updateGlucosePeaks() {
        if showGlucosePeaks {
            glucosePeaks = PeakPicker.pick(
                data: glucoseFromPersistence,
                windowHours: chartVisibleHours / 4
            )
        } else {
            glucosePeaks = []
        }
    }

    /// Called from `MainChartView` on `.onChange(of: units)` to recompute the glucose-derived chart state.
    func setupGlucoseArray() {
        Task { @MainActor in
            updateGlucoseFromController()
        }
    }
}
