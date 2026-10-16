import SwiftUI

// MARK: - Корневой экран: две вкладки снизу

struct ContentView: View {
    @StateObject private var render = RenderViewModel()
    @StateObject private var color = ColorViewModel()
    @StateObject private var license = LicenseManager()
    @Environment(\.scenePhase) private var scenePhase
    @State private var tab = 0

    var body: some View {
        Group {
            if license.isUnlocked {
                mainContent
            } else {
                ActivationView(license: license)
            }
        }
        .preferredColorScheme(.dark)
        .onChange(of: scenePhase) { _, phase in
            if phase == .active { license.refresh() }
        }
    }

    private var mainContent: some View {
        ZStack {
            Theme.background.ignoresSafeArea()
            if tab == 0 {
                RenderScreen(render: render, license: license)
            } else {
                ColorScreen(color: color, render: render) { tab = 0 }
            }
        }
        .safeAreaInset(edge: .bottom) {
            BottomBar(selection: $tab)
        }
        .onChange(of: render.sourceURL) { _, url in
            Task { await color.setSource(url) }
        }
        .onChange(of: tab) { _, _ in
            render.player?.pause()
            color.player?.pause()
            render.refreshColorState()
        }
        .onAppear { render.refreshColorState() }
    }
}

// MARK: - Нижняя панель

struct BottomBar: View {
    @Binding var selection: Int

    var body: some View {
        HStack(spacing: 6) {
            item(0, title: "Рендер", icon: "play.fill")
            item(1, title: "Цвет", icon: "paintpalette.fill")
        }
        .padding(6)
        .background(Theme.panel, in: RoundedRectangle(cornerRadius: 26, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 26, style: .continuous).stroke(Theme.stroke, lineWidth: 1)
        )
        .padding(.horizontal, 16)
        .padding(.top, 6)
        .padding(.bottom, 4)
    }

    private func item(_ index: Int, title: String, icon: String) -> some View {
        let selected = selection == index
        return Button {
            selection = index
        } label: {
            HStack(spacing: 8) {
                Image(systemName: icon)
                    .font(.system(size: 16, weight: .bold))
                Text(title)
                    .font(.system(size: 16, weight: .semibold))
            }
            .foregroundStyle(selected ? Color.black : Theme.textSecondary)
            .frame(maxWidth: .infinity)
            .frame(height: 48)
            .background(
                selected ? Color.white : Color.clear,
                in: RoundedRectangle(cornerRadius: 20, style: .continuous)
            )
        }
        .buttonStyle(.plain)
    }
}
