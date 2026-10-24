import SwiftUI
import TVServices

@main
struct SonosTVApp: App {
    @State private var household = SonosHousehold()

    var body: some Scene {
        WindowGroup {
            NowPlayingView(household: household)
                .task { household.start() }
                // Ask tvOS to reload the Top Shelf whenever any room's playback changes.
                .onChange(of: household.groups) {
                    TVTopShelfContentProvider.topShelfContentDidChange()
                }
        }
    }
}
