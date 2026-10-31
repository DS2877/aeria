import SwiftUI

@main
struct AeriaApp: App {
    @State private var environment = AppEnvironment.live()
    @Environment(\.scenePhase) private var scenePhase

    var body: some Scene {
        WindowGroup {
            RootView()
                .environment(environment)
                .task {
                    environment.network.start()
                    await environment.startUp()
                }
                .onOpenURL { environment.open($0) }
                // Resume points are written on a short debounce; a suspended
                // app may never run it, so save the moment we leave the screen.
                .onChange(of: scenePhase) { _, phase in
                    if phase != .active { environment.watchProgress.flush() }
                }
        }
    }
}
