import SwiftUI

@main
struct LlamaSwiftUIApp: App {
    @StateObject private var store = ProblemStore()

    var body: some Scene {
        WindowGroup {
            SplashView()
                .environmentObject(store)
        }
    }
}

