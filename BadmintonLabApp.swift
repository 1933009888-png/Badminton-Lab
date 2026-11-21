import SwiftUI

@main
struct BadmintonLabApp: App {
    var body: some Scene {
        WindowGroup {
            BadmintonLabRoot()
                .tint(Color("BrandAccent"))
        }
    }
}

private struct BadmintonLabRoot: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var showingIntro = true
    @State private var inFlight = false

    var body: some View {
        ZStack {
            ContentView()
                .accessibilityHidden(showingIntro)
                .allowsHitTesting(!showingIntro)

            if showingIntro {
                ZStack {
                    Color("LaunchOrange").ignoresSafeArea()
                    VStack(spacing: 22) {
                        Image("LaunchShuttle")
                            .resizable()
                            .scaledToFit()
                            .frame(width: 132, height: 132)
                            .rotationEffect(.degrees(inFlight || reduceMotion ? 0 : -14))
                            .offset(x: inFlight || reduceMotion ? 0 : -40,
                                    y: inFlight || reduceMotion ? 0 : 30)
                            .accessibilityHidden(true)
                        Text("Badminton Lab")
                            .font(.system(.largeTitle, design: .rounded).weight(.bold))
                            .foregroundStyle(.white)
                    }
                }
                .zIndex(1)
                .transition(.opacity)
                .task {
                    if !reduceMotion {
                        withAnimation(.easeOut(duration: 0.65)) { inFlight = true }
                    }
                    do {
                        try await Task.sleep(for: .milliseconds(reduceMotion ? 350 : 1400))
                    } catch {
                        return
                    }
                    withAnimation(.easeOut(duration: reduceMotion ? 0 : 0.22)) {
                        showingIntro = false
                    }
                }
            }
        }
    }
}
