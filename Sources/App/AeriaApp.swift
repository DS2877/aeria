import SwiftUI

@main
struct AeriaApp: App {
    @State private var environment = AppEnvironment.live()

    var body: some Scene {
        WindowGroup {
            RootView()
                .environment(environment)
                .task {
                    environment.network.start()
                    await environment.startUp()
                }
                .onOpenURL { environment.open($0) }
        }
    }
}
