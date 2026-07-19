import CoreData
import SwiftUI

// MARK: - Zone C: horizontal pump panel (reservoir / battery / expiry / AISR / TDD)

extension Home.RootView {
    var pumpView: some View {
        PumpView(
            reservoir: state.reservoir,
            name: state.pumpName,
            expiresAtDate: state.pumpExpiresAtDate,
            activatedAtDate: state.pumpActivatedAtDate,
            timerDate: state.timerDate,
            pumpStatusHighlightMessage: state.pumpStatusHighlightMessage,
            battery: state.batteryFromPersistence
        )
        .onTapGesture {
            if state.pumpDisplayState == nil {
                // shows user confirmation dialog with pump model choices, then proceeds to setup
                showPumpSelection.toggle()
            } else {
                // sends user to pump settings
                state.shouldDisplayPumpSetupSheet.toggle()
            }
        }
    }

    var horizontalPumpView: some View {
        HorizontalPumpView(
            reservoir: state.reservoir,
            name: state.pumpName,
            expiresAtDate: state.pumpExpiresAtDate,
            timerDate: state.timerDate,
            pumpStatusHighlightMessage: state.pumpStatusHighlightMessage,
            battery: state.batteryFromPersistence,
            autoISFratio: (
                state.autoisfEnabled
                    ? (state.enactedAndNonEnactedDeterminations.first?.autoISFratio ?? 1)
                    : (state.enactedAndNonEnactedDeterminations.first?.sensitivityRatio ?? 1)
            ) as Decimal,
            totalDaily: state.fetchedTDDs.first?.totalDailyDose ?? 0,
            autoisfEnabled: state.autoisfEnabled,
            showPumpSelection: $showPumpSelection,
            shouldDisplayPumpSetupSheet: $state.shouldDisplayPumpSetupSheet,
            pumpSet: state.pumpSet,
            onTDDTap: {
                // Set preferences in AppState
                appState.statSelectedViewType = .insulin
                appState.statSelectedInsulinChartType = .totalDailyDose
                appState.statSelectedInsulinTimeInterval = .week

                // Show statistics modal
                state.showModal(for: .statistics)
            },
            onAISRTap: {
                // Show autoISF history
                state.showModal(for: .autoISFHistory)
            },
            concentration: state.concentration
        )
    }
}
