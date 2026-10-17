import SwiftUI
import PhotosUI
import AVKit

/// Экраны, которые открываются из вкладки «Видео»
enum VideoRoute: Hashable {
    case color
    case grade(GradeGroup)
}

// MARK: - Видео

struct VideoScreen: View {
    @ObservedObject var render: RenderViewModel
    @ObservedObject var color: ColorViewModel
    @Binding var tab: AppTab

    @State private var path: [VideoRoute] = []
    @State private var pickerItem: PhotosPickerItem?

    var body: some View {
        NavigationStack(path: $path) {
            List {
                if let crash = render.previousCrash {
                    Section {
                        VStack(alignment: .leading, spacing: 4) {
                            Label("Прошлый рендер оборвался вылетом", systemImage: "exclamationmark.triangle")
                                .font(.system(size: 15, weight: .semibold))
                                .foregroundStyle(Theme.text)
                            Text("Последний этап: \(crash)")
                                .font(.system(size: 13))
                                .foregroundStyle(Theme.text2)
                        }
                        .padding(.vertical, 3)
                        ActionRow(title: "Скрыть") { render.dismissCrashNote() }
                    }
                    .surfaceRow()
                }

                Section {
                    VideoStage(render: render, pickerItem: $pickerItem)
                        .listRowInsets(EdgeInsets())
                        .listRowBackground(Color.clear)
                        .listRowSeparator(.hidden)
                        .rise(1)

                    if render.info != nil {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(render.fileName)
                                .font(.system(size: 16, weight: .semibold))
                                .foregroundStyle(Theme.text)
                                .lineLimit(1)
                                .truncationMode(.middle)
                            Text(render.videoMeta)
                                .font(.system(size: 13))
                                .foregroundStyle(Theme.text2)
                        }
                        .listRowInsets(EdgeInsets(top: 12, leading: 4, bottom: 0, trailing: 4))
                        .listRowBackground(Color.clear)
                        .listRowSeparator(.hidden)
                        .transition(.opacity.combined(with: .move(edge: .top)))
                    }
                } footer: {
                    if case .failed(let message) = render.state {
                        Label(message, systemImage: "exclamationmark.triangle")
                            .font(.system(size: 13))
                            .foregroundStyle(Theme.text2)
                    }
                }

                Section {
                    SwitchRow(
                        title: "Нейро-улучшение",
                        sub: render.neuralAvailable
                            ? "Убирает шум и артефакты сжатия, дорисовывает текстуры. Очень долго: рендер растёт в десятки раз, телефон греется."
                            : "Нейромодель не попала в сборку. Нужны логи конвертации на GitHub (блок Annotations).",
                        tag: "Эксперимент",
                        isOn: $render.neuralEnabled,
                        disabled: !render.neuralAvailable
                    )
                    if render.neuralEnabled && render.neuralAvailable {
                        ForEach(NeuralModel.available) { model in
                            TickRow(
                                title: model.title,
                                sub: model.details,
                                selected: render.neuralModel == model,
                                indent: true
                            ) {
                                render.neuralModel = model
                            }
                        }
                        GradeSlider(
                            title: "Сила нейро-эффекта",
                            value: $render.neuralStrength,
                            range: 10...100,
                            neutral: 60,
                            format: "%.0f",
                            step: 5
                        )
                        .padding(.leading, 16)
                    }
                } header: {
                    SectionLabel("Улучшение")
                }
                .surfaceRow()
                .rise(2)

                Section {
                    ChevronRow(title: "Плавность", value: render.smoothSummary) { tab = .smooth }
                    ChevronRow(title: "Качество", value: render.qualitySummary) { tab = .quality }
                    NavigationLink(value: VideoRoute.color) {
                        HStack {
                            ItemLabel(title: "Цвет")
                            Spacer(minLength: 8)
                            RollText(text: colorSummary)
                                .font(.system(size: 16))
                                .foregroundStyle(Theme.text2)
                        }
                    }
                } header: {
                    SectionLabel("Параметры рендера")
                }
                .surfaceRow()
                .rise(3)
            }
            .themedList()
            .animation(Theme.soft, value: render.neuralEnabled)
            .animation(Theme.soft, value: render.info != nil)
            .navigationTitle("Рендер")
            .navigationDestination(for: VideoRoute.self) { route in
                switch route {
                case .color:
                    ColorScreen(color: color, render: render) { path.removeAll() }
                case .grade(let group):
                    GradeGroupScreen(group: group, color: color)
                }
            }
        }
        .onChange(of: pickerItem) { _, item in
            guard let item else { return }
            Task {
                await render.load(item)
                pickerItem = nil
            }
        }
    }

    private var colorSummary: String {
        if render.applyColor { return "Вкл" }
        return render.colorReady ? "Выкл" : "Не настроен"
    }
}

// MARK: - Блок выбора видео

/// Карточка загрузки, которая после выбора превращается в плеер
private struct VideoStage: View {
    @ObservedObject var render: RenderViewModel
    @Binding var pickerItem: PhotosPickerItem?

    private var loaded: Bool { render.player != nil && !render.isLoading }

    var body: some View {
        ZStack {
            PhotosPicker(selection: $pickerItem, matching: .videos) {
                UploadCard(loading: render.isLoading, progress: render.loadProgress)
            }
            .buttonStyle(PressStyle(scale: 0.98))
            .disabled(render.isRendering || render.isLoading)
            .opacity(loaded ? 0 : 1)
            .scaleEffect(loaded ? 0.94 : 1)
            .blur(radius: loaded ? 8 : 0)
            .allowsHitTesting(!loaded)

            if let player = render.player {
                MediaView(player: player) {
                    PhotosPicker(selection: $pickerItem, matching: .videos) {
                        MediaCornerLabel(title: "Заменить", icon: "arrow.left.arrow.right")
                    }
                    .buttonStyle(PressStyle())
                    .disabled(render.isRendering || render.isLoading)
                }
                .opacity(loaded ? 1 : 0)
                .scaleEffect(loaded ? 1 : 1.04)
                .blur(radius: loaded ? 0 : 10)
                .allowsHitTesting(loaded)
            }
        }
        .frame(height: 260)
        .animation(Theme.soft.delay(loaded ? 0.12 : 0), value: loaded)
        .shake(render.loadFailCount)
    }
}

private struct UploadCard: View {
    let loading: Bool
    let progress: Double

    var body: some View {
        VStack(spacing: 6) {
            UploadOrb(loading: loading, progress: progress)
                .padding(.bottom, 16)
            ZStack {
                VStack(spacing: 6) {
                    Text("Выбери видео")
                        .font(.system(size: 18, weight: .semibold))
                        .tracking(-0.3)
                    Text("Нажми, чтобы загрузить из галереи")
                        .font(.system(size: 13.5))
                        .foregroundStyle(Theme.text2)
                }
                .opacity(loading ? 0 : 1)
                .offset(y: loading ? -8 : 0)

                VStack(spacing: 6) {
                    Text("Загружаю")
                        .font(.system(size: 18, weight: .semibold))
                        .tracking(-0.3)
                    Text("\(Int(progress * 100))%")
                        .font(.system(size: 13.5).monospacedDigit())
                        .foregroundStyle(Theme.text2)
                        .contentTransition(.numericText())
                }
                .opacity(loading ? 1 : 0)
                .offset(y: loading ? 0 : 8)
            }
        }
        .foregroundStyle(Theme.text)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Theme.surface)
        .clipShape(RoundedRectangle(cornerRadius: 26, style: .continuous))
        .contentShape(RoundedRectangle(cornerRadius: 26, style: .continuous))
        .animation(Theme.soft, value: loading)
    }
}

// MARK: - Плавность

struct SmoothScreen: View {
    @ObservedObject var render: RenderViewModel
    @EnvironmentObject private var ui: AppUI

    private let rates = [60, 90, 120]

    var body: some View {
        NavigationStack {
            List {
                Section {
                    SwitchRow(
                        title: "Умный темп кадров",
                        sub: "В записях игр кадры часто приходят неровно или повторяются. Приложение пропускает повторы и достраивает кадры на ровной сетке, движение становится плавнее. Рекомендуется.",
                        isOn: $render.smartPacing
                    )
                    if render.smartPacing {
                        ValueRow(title: "Частота кадров", value: "\(render.targetFPS) к/с") {
                            ui.pick(
                                "Частота кадров",
                                options: rates.map { SheetOption(title: "\($0) к/с", detail: $0 == 120 ? "Рекомендуется для ProMotion" : nil) },
                                selected: rates.firstIndex(of: render.targetFPS)
                            ) { render.targetFPS = rates[$0] }
                        }
                    }
                    SwitchRow(
                        title: "Сглаживание",
                        sub: "Режим повышенного качества расчёта движения. На резких поворотах камеры может рвать картинку, тогда выключи.",
                        tag: "Эксперимент",
                        isOn: $render.smoothing
                    )
                } footer: {
                    Note(render.smartPacing
                         ? "Больше кадров — плавнее движение, но рендер займёт больше времени."
                         : "Выключено: каждый кадр просто удваивается (например, 60 → 120).")
                }
                .surfaceRow()
                .rise(1)

                Section {
                    GradeSlider(
                        title: "Сила размытия",
                        value: $render.motionBlur,
                        range: 0...100,
                        neutral: 0,
                        format: "%.0f",
                        step: 5
                    )
                } header: {
                    SectionLabel("Размытие движения")
                } footer: {
                    Note("Имитирует выдержку камеры: быстрые объекты слегка смазываются. Для максимальной чёткости держи выключенным. Рендер идёт заметно дольше.")
                }
                .surfaceRow()
                .rise(2)
            }
            .themedList()
            .animation(Theme.soft, value: render.smartPacing)
            .navigationTitle("Плавность")
        }
    }
}

// MARK: - Качество

struct QualityScreen: View {
    @ObservedObject var render: RenderViewModel
    @EnvironmentObject private var ui: AppUI

    var body: some View {
        NavigationStack {
            List {
                Section {
                    ValueRow(title: "Кодек", value: render.codec.title) {
                        let codecs = VideoCodec.allCases
                        ui.pick(
                            "Кодек",
                            options: codecs.map { SheetOption(title: $0.title) },
                            selected: codecs.firstIndex(of: render.codec)
                        ) { render.codec = codecs[$0] }
                    }
                    if render.codec.usesBitrate {
                        ValueRow(title: "Битрейт", value: "\(Int(render.bitrate)) Мбит/с") {
                            let values = BitratePresets.values(including: render.bitrate)
                            ui.pick(
                                "Битрейт",
                                options: values.map { SheetOption(title: "\(Int($0)) Мбит/с") },
                                selected: values.firstIndex(of: render.bitrate)
                            ) { render.bitrate = values[$0] }
                        }
                        GradeSlider(
                            title: "Точное значение, Мбит/с",
                            value: $render.bitrate,
                            range: 5...150,
                            neutral: RenderDefaults.bitrate,
                            format: "%.0f",
                            step: 5
                        )
                    }
                } footer: {
                    Note(qualityNote)
                }
                .surfaceRow()
                .rise(1)

                Section {
                    GradeSlider(
                        title: "Резкость",
                        value: $render.sharpness,
                        range: 0...100,
                        neutral: 0,
                        format: "%.0f",
                        step: 5
                    )
                } header: {
                    SectionLabel("Резкость достроенных кадров")
                } footer: {
                    Note("Подтягивает чёткость промежуточных кадров, они обычно мягче оригинальных. Исходные кадры не меняются.")
                }
                .surfaceRow()
                .rise(2)
            }
            .themedList()
            .animation(Theme.soft, value: render.codec)
            .navigationTitle("Качество")
        }
    }

    private var qualityNote: String {
        var text = render.codec.details
        if render.codec.usesBitrate {
            text += "\n\nВысокий битрейт сохраняет мелкие детали, но файл получится тяжелее."
        }
        if render.info != nil {
            text += " ≈ \(Int(render.estimatedSizeMB)) МБ"
            if !render.codec.usesBitrate { text += " (ориентировочно, у ProRes нет битрейта)" }
            text += "."
        }
        return text
    }
}

/// Готовые значения битрейта для шита
enum BitratePresets {
    static let base: [Double] = [10, 20, 40, 60, 80, 120, 150]

    static func values(including current: Double) -> [Double] {
        base.contains(current) ? base : (base + [current]).sorted()
    }
}

// MARK: - Задачи

struct TasksScreen: View {
    @ObservedObject var render: RenderViewModel

    var body: some View {
        NavigationStack {
            List {
                Section {
                    if render.jobs.isEmpty {
                        VStack(spacing: 4) {
                            Text("Пока пусто")
                                .font(.system(size: 16, weight: .semibold))
                                .foregroundStyle(Theme.text)
                            Text("Запусти рендер, и готовые ролики появятся здесь.")
                                .font(.system(size: 13.5))
                                .foregroundStyle(Theme.text2)
                                .multilineTextAlignment(.center)
                        }
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 36)
                        .padding(.horizontal, 8)
                    } else {
                        ForEach(render.jobs) { job in
                            JobRow(
                                job: job,
                                expanded: render.expandedJob == job.id,
                                player: render.expandedJob == job.id ? render.resultPlayer : nil
                            ) {
                                withAnimation(Theme.soft) { render.toggleExpand(job) }
                            }
                        }
                    }
                }
                .surfaceRow()
                .rise(1)
            }
            .themedList()
            .animation(Theme.soft, value: render.jobs.map(\.id))
            .navigationTitle("Задачи")
        }
    }
}

private struct JobRow: View {
    let job: RenderJob
    let expanded: Bool
    let player: AVPlayer?
    let onTap: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Button(action: onTap) {
                HStack(spacing: 12) {
                    ItemLabel(title: job.name, sub: subtitle)
                    Spacer(minLength: 8)
                    status
                        .frame(width: 22, height: 22)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            if expanded, let url = job.url {
                if let player {
                    MediaView(player: player, cornerRadius: 16) { EmptyView() }
                        .frame(height: 220)
                }
                if let message = job.message {
                    Text(message)
                        .font(.system(size: 13))
                        .foregroundStyle(Theme.text2)
                }
                ShareLink(item: url) {
                    Label("Поделиться файлом", systemImage: "square.and.arrow.up")
                        .font(.system(size: 16, weight: .semibold))
                        .frame(maxWidth: .infinity, minHeight: 36)
                }
                .buttonStyle(.glass)
                .tint(Theme.text)
                .padding(.bottom, 4)
            }
        }
    }

    private var subtitle: String {
        if case .failed(let message) = job.status { return message }
        return job.summary
    }

    @ViewBuilder
    private var status: some View {
        switch job.status {
        case .running(let value):
            ProgressRing(value: value)
                .animation(.linear(duration: 0.2), value: value)
        case .done:
            AppearingTick()
                .foregroundStyle(Theme.text)
        case .failed:
            Image(systemName: "exclamationmark.triangle")
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(Theme.text2)
        }
    }
}

// MARK: - Настройки

struct SettingsScreen: View {
    @ObservedObject var render: RenderViewModel
    @ObservedObject var license: LicenseManager
    @EnvironmentObject private var ui: AppUI
    @AppStorage(ThemeChoice.storageKey) private var themeRaw = ThemeChoice.system.rawValue

    var body: some View {
        NavigationStack {
            List {
                Section {
                    LabeledContent("Статус", value: license.statusText)
                    if case .active(let payload) = license.state {
                        LabeledContent("Ключ", value: payload.id)
                    }
                    Button {
                        UIPasteboard.general.string = license.deviceCode
                        ui.show("Код скопирован")
                    } label: {
                        LabeledContent("Код устройства") {
                            HStack(spacing: 6) {
                                Text(license.deviceCode).monospaced()
                                Image(systemName: "doc.on.doc")
                                    .font(.system(size: 13, weight: .semibold))
                            }
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    if case .active = license.state {
                        ActionRow(title: "Сменить ключ", icon: "key") { license.deactivate() }
                            .disabled(render.isRendering)
                            .opacity(render.isRendering ? 0.5 : 1)
                    }
                } header: {
                    SectionLabel("Лицензия")
                }
                .foregroundStyle(Theme.text)
                .surfaceRow()
                .rise(1)

                Section {
                    ForEach(ThemeChoice.allCases) { choice in
                        TickRow(title: choice.title, selected: themeRaw == choice.rawValue) {
                            themeRaw = choice.rawValue
                        }
                    }
                } header: {
                    SectionLabel("Оформление")
                }
                .surfaceRow()
                .rise(2)

                Section {
                    ActionRow(title: "Сбросить настройки рендера") {
                        render.resetSettings()
                        ui.show("Настройки рендера сброшены")
                    }
                    .disabled(render.isRendering)
                    .opacity(render.isRendering ? 0.5 : 1)
                    LabeledContent("Версия", value: appVersion)
                        .foregroundStyle(Theme.text)
                }
                .surfaceRow()
                .rise(3)
            }
            .themedList()
            .navigationTitle("Настройки")
        }
    }

    private var appVersion: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "1.0"
    }
}
