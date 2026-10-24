import SwiftUI

@main
struct SonosTVApp: App {
    @State private var household = SonosHousehold()

    var body: some Scene {
        WindowGroup {
            NowPlayingView(household: household)
                .task { household.start() }
        }
    }
}
