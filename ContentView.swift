import SwiftUI
import Combine

enum AppTab: Hashable {
    case video
    case smooth
    case quality
    case tasks
    case settings
}

// MARK: - Корневой экран: пять вкладок снизу, кнопка рендера над ними

struct ContentView: View {
    @StateObject private var render = RenderViewModel()
    @StateObject private var color = ColorViewModel()
    @StateObject private var license = LicenseManager()
    @StateObject private var ui = AppUI()
    @AppStorage(ThemeChoice.storageKey) private var themeRaw = ThemeChoice.system.rawValue
    @Environment(\.scenePhase) private var scenePhase
    @State private var tab: AppTab = .video
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
        .overlay(alignment: .top) { ToastHost() }
        .sheet(item: $ui.sheet) { config in
            OptionSheet(config: config)
                .environmentObject(ui)
        }
        .environmentObject(ui)
        .preferredColorScheme((ThemeChoice(rawValue: themeRaw) ?? .system).scheme)
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
        TabView(selection: $tab) {
            Tab("Видео", systemImage: "play.rectangle", value: AppTab.video) {
                VideoScreen(render: render, color: color, tab: $tab)
            }
            Tab("Плавность", systemImage: "gauge.with.needle", value: AppTab.smooth) {
                SmoothScreen(render: render)
            }
            Tab("Качество", systemImage: "sparkles", value: AppTab.quality) {
                QualityScreen(render: render)
            }
            Tab("Задачи", systemImage: "checkmark.square", value: AppTab.tasks) {
                TasksScreen(render: render)
            }
            .badge(render.unseenDone)
            Tab("Настройки", systemImage: "slider.horizontal.3", value: AppTab.settings) {
                SettingsScreen(render: render, license: license)
            }
        }
        .tint(Theme.text)
        .modifier(RenderAccessory(enabled: showCTA, render: render) { tab = .video })
        .onChange(of: render.sourceURL) { _, url in
            Task { await color.setSource(url) }
        }
        .onChange(of: tab) { _, newTab in
            render.player?.pause()
            color.player?.pause()
            render.refreshColorState()
            if newTab == .tasks { render.unseenDone = 0 }
        }
        .onChange(of: render.unseenDone) { _, count in
            if count > 0 && tab == .tasks { render.unseenDone = 0 }
        }
        // Цвет: предпросмотр и общий снимок для рендера обновляются при любом изменении
        .onChange(of: color.params) { _, _ in colorChanged() }
        .onChange(of: color.match) { _, _ in colorChanged() }
        .onChange(of: color.showOriginal) { _, _ in color.pushPreview() }
        // Сообщения о результате — тостами
        .onChange(of: render.finishCount) { _, _ in ui.show(render.lastMessage) }
        .onChange(of: render.failCount) { _, _ in ui.show(render.lastMessage, tick: false) }
        .onChange(of: render.loadFailCount) { _, _ in
            if case .failed(let message) = render.state { ui.show(message, tick: false) }
        }
        .onChange(of: color.resultMessage) { _, message in
            if let message { ui.show(message) }
        }
        .onChange(of: color.errorMessage) { _, message in
            if let message { ui.show(message, tick: false) }
        }
        .onAppear { render.refreshColorState() }
    }

    /// Кнопка рендера видна на первых трёх вкладках, когда видео загружено
    private var showCTA: Bool {
        render.info != nil && (tab == .video || tab == .smooth || tab == .quality)
    }

    private func colorChanged() {
        color.pushPreview()
        render.refreshColorState()
    }
}

// MARK: - Кнопка рендера над таб-баром

private struct RenderAccessory: ViewModifier {
    let enabled: Bool
    @ObservedObject var render: RenderViewModel
    let goToVideo: () -> Void

    @ViewBuilder
    func body(content: Content) -> some View {
        if #available(iOS 26.1, *) {
            content.tabViewBottomAccessory(isEnabled: enabled) {
                RenderCTA(render: render, goToVideo: goToVideo)
            }
        } else {
            content.tabViewBottomAccessory {
                RenderCTA(render: render, goToVideo: goToVideo)
            }
        }
    }
}

struct RenderCTA: View {
    @ObservedObject var render: RenderViewModel
    let goToVideo: () -> Void

    @Environment(\.tabViewBottomAccessoryPlacement) private var placement
    @State private var showDone = false
    @State private var popped = false

    private enum Phase {
        case noVideo, idle, busy, done
    }

    private var phase: Phase {
        if showDone { return .done }
        if render.isRendering { return .busy }
        return render.info == nil ? .noVideo : .idle
    }

    private var progress: Double {
        if case .rendering(let value) = render.state { return value }
        return showDone ? 1 : 0
    }

    var body: some View {
        Group {
            if placement == .inline {
                compact
            } else {
                expanded
            }
        }
        .shake(render.failCount)
        .onAppear {
            withAnimation(Theme.spring) { popped = true }
        }
        .onChange(of: render.finishCount) { _, _ in
            withAnimation(Theme.soft) { showDone = true }
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.8) {
                withAnimation(Theme.soft) { showDone = false }
            }
        }
    }

    // MARK: Полный вид

    private var expanded: some View {
        ZStack(alignment: .trailing) {
            Button(action: tap) {
                HStack(spacing: 12) {
                    icon
                        .frame(width: 44, height: 44)
                        .background(Theme.ctaChip, in: Circle())
                        .scaleEffect(popped ? 1 : 0.4)
                    VStack(alignment: .leading, spacing: 1) {
                        Text(title)
                            .font(.system(size: 16.5, weight: .semibold))
                            .tracking(-0.3)
                            .contentTransition(.numericText())
                        Text(subtitle)
                            .font(.system(size: 12.5, weight: .medium))
                            .opacity(0.55)
                            .lineLimit(1)
                    }
                    Spacer(minLength: 8)
                    trailing
                }
                .padding(.leading, 9)
                .padding(.trailing, 20)
                .frame(maxWidth: .infinity)
                .frame(height: 62)
                .foregroundStyle(Theme.onAccent)
                .background { background }
                .contentShape(Capsule())
            }
            .buttonStyle(PressStyle(scale: 0.97))

            if phase == .busy {
                Button {
                    render.cancel()
                } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: 14, weight: .bold))
                        .foregroundStyle(Theme.onAccent)
                        .frame(width: 36, height: 36)
                        .glassEffect(.regular.interactive(), in: .circle)
                }
                .buttonStyle(PressStyle())
                .padding(.trailing, 13)
                .transition(.scale(scale: 0.5).combined(with: .opacity))
                .accessibilityLabel("Отменить рендер")
            }
        }
        .animation(Theme.spring, value: phase == .busy)
    }

    private var background: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                Theme.accent
                Theme.ctaFill
                    .frame(width: geo.size.width * progress)
                    .opacity(phase == .busy || phase == .done ? 1 : 0)
                    .animation(.linear(duration: 0.2), value: progress)
            }
        }
        .clipShape(Capsule())
        .shadow(color: .black.opacity(0.3), radius: 15, y: 10)
    }

    @ViewBuilder
    private var trailing: some View {
        switch phase {
        case .busy:
            Color.clear.frame(width: 36, height: 36)
        case .idle:
            HStack(spacing: 5) {
                Image(systemName: "internaldrive")
                    .font(.system(size: 13, weight: .semibold))
                RollText(text: "≈ \(Int(render.estimatedSizeMB)) МБ")
            }
            .font(.system(size: 14, weight: .semibold))
            .opacity(0.7)
            .transition(.opacity.combined(with: .offset(x: 10)))
        default:
            EmptyView()
        }
    }

    private var icon: some View {
        ZStack {
            Image(systemName: "play.fill")
                .font(.system(size: 17))
                .offset(x: 1)
                .opacity(phase == .idle || phase == .noVideo ? 1 : 0)
                .scaleEffect(phase == .busy ? 0.4 : 1)
                .rotationEffect(.degrees(phase == .busy ? -90 : 0))
            ProgressRing(value: progress, lineWidth: 2.6, track: Theme.onAccent.opacity(0.2), tint: Theme.onAccent)
                .frame(width: 30, height: 30)
                .opacity(phase == .busy ? 1 : 0)
                .scaleEffect(phase == .busy ? 1 : (phase == .done ? 1.3 : 0.5))
            TickMark(drawn: phase == .done)
                .opacity(phase == .done ? 1 : 0)
                .scaleEffect(phase == .done ? 1 : 0.5)
        }
        .animation(Theme.spring, value: phase)
    }

    // MARK: Свёрнутый вид (таб-бар уменьшен)

    private var compact: some View {
        Button(action: tap) {
            HStack(spacing: 8) {
                icon
                    .frame(width: 26, height: 26)
                    .scaleEffect(0.8)
                Text(phase == .busy ? "\(Int(progress * 100))%" : title)
                    .font(.system(size: 14, weight: .semibold))
                    .contentTransition(.numericText())
                    .lineLimit(1)
            }
            .padding(.horizontal, 14)
            .frame(maxWidth: .infinity)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    // MARK: Тексты

    private var title: String {
        switch phase {
        case .noVideo: return "Начать рендер"
        case .idle: return "Начать рендер"
        case .busy: return progress < 0.005 ? "Подготовка" : "Рендер \(Int(progress * 100))%"
        case .done: return "Готово"
        }
    }

    private var subtitle: String {
        switch phase {
        case .noVideo:
            return "Сначала выбери видео"
        case .idle:
            return render.renderSummary
        case .busy:
            if let left = remaining { return "\(render.stageText) · осталось \(left)" }
            return render.stageText
        case .done:
            return render.savedToPhotos ? "Сохранено в Фото" : "Сохранено в Файлы"
        }
    }

    /// Оставшееся время по прошедшему времени и прогрессу
    private var remaining: String? {
        guard case .rendering(let p) = render.state, p > 0.02, let start = render.renderStartedAt else { return nil }
        let elapsed = Date().timeIntervalSince(start)
        let left = max(1, Int((elapsed * (1 - p) / p).rounded(.up)))
        return left < 60 ? "\(left) с" : String(format: "%d:%02d", left / 60, left % 60)
    }

    private func tap() {
        switch phase {
        case .noVideo:
            goToVideo()
        case .idle:
            render.render()
        case .busy, .done:
            break
        }
    }
}
