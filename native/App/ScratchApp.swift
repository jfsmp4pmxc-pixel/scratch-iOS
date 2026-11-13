import SwiftUI

@main
struct ScratchApp: App {
    @StateObject private var store = ProjectStore()

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(store)
                .onOpenURL { url in store.open(url: url) }
        }
    }
}
