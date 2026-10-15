import SwiftUI

@main
struct SmoothFramesApp: App {
    var body: some Scene {
        WindowGroup {
            TabView {
                ContentView()
                    .tabItem { Label("Рендер", systemImage: "film") }
                ColorView()
                    .tabItem { Label("Цвет", systemImage: "slider.horizontal.3") }
            }
        }
    }
}
