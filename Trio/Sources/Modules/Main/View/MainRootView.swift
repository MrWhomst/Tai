import SwiftUI
import Swinject

/// Set to `true` for views presented in MainRootView's modal sheet wrappers. Lets sheet
/// content show modal-only chrome (e.g. an explicit Close button) without also showing it
/// when the same view is pushed onto a NavigationStack — `\.isPresented` returns true for
/// nav pushes too, which is why a custom key is needed.
private struct IsInModalSheetKey: EnvironmentKey {
    static let defaultValue = false
}

extension EnvironmentValues {
    var isInModalSheet: Bool {
        get { self[IsInModalSheetKey.self] }
        set { self[IsInModalSheetKey.self] = newValue }
    }
}

extension Main {
    struct RootView: BaseView {
        let resolver: Resolver
        @StateObject var state = StateModel()

        @Environment(\.colorScheme) var colorScheme
        @Environment(AppState.self) var appState

        /// Default `SettingsSearchHighlight` so any `SettingInputSection` rendered outside the
        /// Settings tab (e.g. in Adjustments / AdaptProfile modals) finds an instance in the
        /// environment instead of tripping SwiftUI's missing-Observable assertion. The Settings
        /// tab injects its own instance, which overrides this one inside that subtree.
        @State private var defaultSettingsSearchHighlight = SettingsSearchHighlight()

        private var modalScheduler: TrioModalAlertScheduler {
            resolver.resolve(TrioAlertManager.self)!.modalScheduler
        }

        var body: some View {
            router.view(for: .home)
                .sheet(item: $state.modal) { modal in
                    NavigationView { modal.view.environment(\.isInModalSheet, true) }
                        .navigationViewStyle(StackNavigationViewStyle())
                }
                .sheet(item: $state.secondaryModal) { wrapper in
                    wrapper.view.environment(\.isInModalSheet, true)
                }
                .trioAlerts(modalScheduler)
                .onAppear(perform: configureView)
                .scrollContentBackground(.hidden).background(appState.trioBackgroundColor(for: colorScheme))
                .environment(defaultSettingsSearchHighlight)
        }
    }
}
