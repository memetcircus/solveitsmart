/*import SwiftUI

@main
struct llama_swiftuiApp: App {
    var body: some Scene {
        WindowGroup {
            ContentView()
        }
    }
}*/

/*
import SwiftUI

@main
struct LlamaSwiftUIApp: App {
    @StateObject private var store = ProblemStore()  // Step 1: Create and store your ProblemStore

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(store)  // Step 2: Inject into environment
        }
    }
}*/

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

