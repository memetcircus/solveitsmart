import SwiftUI

struct SplashView: View {
    @State private var isActive = false
    @EnvironmentObject var store: ProblemStore

    var body: some View {
        Group {
            if isActive {
                ContentView()
                    .environmentObject(store)
            } else {
                ZStack {
                    Color.black.ignoresSafeArea()
                    Image("splash")
                        .resizable()
                        .scaledToFill()
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        .ignoresSafeArea()
                }
                .onAppear {
                    DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) {
                        withAnimation {
                            self.isActive = true
                        }
                    }
                }
            }
        }
    }
}
