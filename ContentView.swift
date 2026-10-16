import SwiftUI
import Combine

// MARK: - Корневой экран: две вкладки снизу

struct ContentView: View {
    @StateObject private var render = RenderViewModel()
    @StateObject private var color = ColorViewModel()
    @StateObject private var license = LicenseManager()
    @Environment(\.scenePhase) private var scenePhase
    @State private var tab = 0
    /// Проверка срока ключа раз в 30 секунд, пока приложение открыто
    private let ticker = Timer.publish(every: 30, on: .main, in: .common).autoconnect()

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
        .onReceive(ticker) { _ in
            license.refresh()
        }
        .onChange(of: license.isUnlocked) { _, unlocked in
            // срок истёк: останавливаем всё, что запущено
            if !unlocked {
                render.cancel()
                color.cancel()
            }
        }
    }

    private var mainContent: some View {
        ZStack {
            Theme.backdrop.ignoresSafeArea()
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
        .background(Theme.panel, in: RoundedRectangle(cornerRadius: 20, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 20, style: .continuous).stroke(Theme.stroke, lineWidth: 1)
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
                    .font(.system(size: 16, weight: .semibold))
                Text(title)
                    .font(.system(size: 16, weight: .semibold))
            }
            .foregroundStyle(selected ? Theme.textPrimary : Theme.textSecondary)
            .frame(maxWidth: .infinity)
            .frame(height: 48)
            .background(
                selected ? Theme.selected : Color.clear,
                in: RoundedRectangle(cornerRadius: 14, style: .continuous)
            )
            .overlay(alignment: .bottom) {
                if selected {
                    Capsule()
                        .fill(Theme.gradient)
                        .frame(width: 44, height: 3)
                        .gradientGlow(cornerRadius: 1.5, radius: 5, intensity: 0.8)
                        .padding(.bottom, 4)
                }
            }
        }
        .buttonStyle(.plain)
    }
}
