import SwiftUI

@main
struct ScratchApp: App {
    @StateObject private var store = ProjectStore()

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(store)
                .environmentObject(store.dragModel)
                .environmentObject(store.highlight)
                .onOpenURL { url in store.open(url: url) }
        }
    }
}
