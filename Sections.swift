import SwiftUI
import PhotosUI
import AVKit

// MARK: - Экран «Рендер»

struct RenderScreen: View {
    @ObservedObject var render: RenderViewModel
    @ObservedObject var license: LicenseManager
    @State private var tab = 0
    @State private var pickerItem: PhotosPickerItem?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                SectionHeader(title: "Рендер", subtitle: "Плавность, качество и сохранение")
                PillTabs(titles: ["Видео", "Плавность", "Качество", "Запуск"], selection: $tab)

                switch tab {
                case 0:
                    videoTab
                case 1:
                    smoothTab
                case 2:
                    qualityTab
                default:
                    runTab
                }
            }
            .padding(.horizontal, 16)
            .padding(.top, 8)
            .padding(.bottom, 24)
        }
        .onChange(of: pickerItem) { _, item in
            Task { await render.load(item) }
        }
    }

    // MARK: Видео

    private var videoTab: some View {
        VStack(alignment: .leading, spacing: 14) {
            if let crash = render.previousCrash {
                VStack(alignment: .leading, spacing: 8) {
                    Label("Прошлый рендер оборвался вылетом", systemImage: "exclamationmark.triangle.fill")
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(.orange)
                    Text("Последний этап: \(crash)")
                        .font(.system(size: 12))
                        .foregroundStyle(Theme.textSecondary)
                    Button("Скрыть") { render.dismissCrashNote() }
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(.white)
                }
                .themedCard()
            }

            if let player = render.player {
                VideoPlayer(player: player)
                    .aspectRatio(16.0 / 9.0, contentMode: .fit)
                    .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
            }

            PhotosPicker(selection: $pickerItem, matching: .videos) {
                PrimaryLabel(
                    title: render.info == nil ? "Выбрать видео" : "Выбрать другое видео",
                    icon: "video.badge.plus"
                )
            }
            .disabled(render.isRendering || render.isLoading)

            if render.isLoading {
                HStack(spacing: 10) {
                    ProgressView().tint(.white)
                    Text("Загружаю видео…").foregroundStyle(Theme.textSecondary)
                }
            }

            if let info = render.info {
                VStack(spacing: 0) {
                    InfoRow(label: "Разрешение", value: "\(info.width)×\(info.height)")
                    InfoRow(label: "Частота кадров", value: "\(Int(info.fps.rounded())) к/с")
                    InfoRow(label: "Длительность", value: formatDuration(info.duration))
                    InfoRow(label: "Битрейт", value: String(format: "%.0f Мбит/с", info.bitrateMbps), divider: false)
                }
                .themedCard()
            }

            if case .failed(let message) = render.state {
                Label(message, systemImage: "exclamationmark.triangle.fill")
                    .font(.system(size: 13))
                    .foregroundStyle(.red)
            }

            licenseCard
        }
    }

    private var licenseCard: some View {
        VStack(alignment: .leading, spacing: 8) {
            SmallCaption(text: "Лицензия")
            VStack(spacing: 0) {
                InfoRow(label: "Статус", value: license.statusText)
                if case .active(let p) = license.state {
                    InfoRow(label: "Ключ", value: p.id)
                }
                InfoRow(label: "Код устройства", value: license.deviceCode, divider: false)
            }
            .themedCard()

            if case .active = license.state {
                PrimaryButton(title: "Сменить ключ", icon: "key.fill", dark: true) { license.deactivate() }
                    .disabled(render.isRendering)
            }
        }
    }

    // MARK: Плавность

    private var smoothTab: some View {
        VStack(alignment: .leading, spacing: 10) {
            SmallCaption(text: "Темп кадров")
            ToggleRow(
                title: "Умный темп кадров",
                caption: "В записях игр кадры часто приходят неровно или повторяются. Приложение пропускает повторы и достраивает кадры на ровной сетке, движение становится плавнее. Рекомендуется.",
                isOn: $render.smartPacing
            )
            if render.smartPacing {
                ForEach([60, 90, 120], id: \.self) { fps in
                    SelectRow(
                        title: "\(fps) к/с",
                        subtitle: fps == 120 ? "Рекомендуется для iPhone с ProMotion" : nil,
                        selected: render.targetFPS == fps
                    ) {
                        render.targetFPS = fps
                    }
                }
            } else {
                Text("Выключено: каждый кадр просто удваивается (например, 60 → 120).")
                    .font(.system(size: 12))
                    .foregroundStyle(Theme.textSecondary)
            }

            SmallCaption(text: "Интерполяция")
            ToggleRow(
                title: "Сглаживание (экспериментально)",
                caption: "Режим повышенного качества расчёта движения. На резких поворотах камеры может рвать картинку, тогда выключи.",
                isOn: $render.smoothing
            )

            SmallCaption(text: "Размытие движения")
            VStack(alignment: .leading, spacing: 12) {
                GradeSlider(
                    title: "Сила размытия",
                    value: $render.motionBlur,
                    range: 0...100,
                    neutral: 0,
                    format: "%.0f",
                    step: 5
                )
                ChipRow(
                    values: [0, 25, 50, 75],
                    current: render.motionBlur,
                    label: { $0 == 0 ? "Выкл" : "\(Int($0))" },
                    action: { render.motionBlur = $0 }
                )
                Text("Имитирует выдержку камеры: быстрые объекты слегка смазываются. Для максимальной чёткости держи выключенным. Рендер идёт заметно дольше.")
                    .font(.system(size: 12))
                    .foregroundStyle(Theme.textSecondary)
            }
            .themedCard()
        }
    }

    // MARK: Качество

    private var qualityTab: some View {
        VStack(alignment: .leading, spacing: 10) {
            SmallCaption(text: "Нейро-улучшение")
            ToggleRow(
                title: "Нейро-улучшение (экспериментально)",
                caption: render.neuralAvailable
                    ? "Убирает шум и артефакты сжатия, дорисовывает текстуры. Очень долго: рендер растёт в десятки раз, телефон греется."
                    : "Нейромодель не попала в сборку. Нужны логи конвертации на GitHub (блок Annotations).",
                isOn: $render.neuralEnabled,
                disabled: !render.neuralAvailable
            )
            if render.neuralEnabled && render.neuralAvailable {
                ForEach(NeuralModel.available) { model in
                    SelectRow(
                        title: model.title,
                        subtitle: model.details,
                        selected: render.neuralModel == model
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
                .themedCard()
            }

            SmallCaption(text: "Резкость достроенных кадров")
            VStack(alignment: .leading, spacing: 12) {
                GradeSlider(
                    title: "Резкость",
                    value: $render.sharpness,
                    range: 0...100,
                    neutral: 0,
                    format: "%.0f",
                    step: 5
                )
                ChipRow(
                    values: [0, 25, 50, 75],
                    current: render.sharpness,
                    label: { $0 == 0 ? "Выкл" : "\(Int($0))" },
                    action: { render.sharpness = $0 }
                )
                Text("Подтягивает чёткость промежуточных кадров, они обычно мягче оригинальных. Исходные кадры не меняются.")
                    .font(.system(size: 12))
                    .foregroundStyle(Theme.textSecondary)
            }
            .themedCard()

            SmallCaption(text: "Кодек")
            ForEach(VideoCodec.allCases) { codec in
                SelectRow(
                    title: codec.title,
                    subtitle: codec.details,
                    selected: render.codec == codec
                ) {
                    render.codec = codec
                }
            }

            if render.codec.usesBitrate {
                VStack(alignment: .leading, spacing: 12) {
                    GradeSlider(
                        title: "Битрейт, Мбит/с",
                        value: $render.bitrate,
                        range: 5...150,
                        neutral: 80,
                        format: "%.0f",
                        step: 5
                    )
                    ChipRow(
                        values: [20, 40, 80, 120],
                        current: render.bitrate,
                        label: { "\(Int($0))" },
                        action: { render.bitrate = $0 }
                    )
                }
                .themedCard()
            }

            Text("≈ \(Int(render.estimatedSizeMB)) МБ · \(render.codec.title)\(render.codec.usesBitrate ? "" : " (ориентировочно, у ProRes нет битрейта)")")
                .font(.system(size: 12))
                .foregroundStyle(Theme.textSecondary)
        }
    }

    // MARK: Запуск

    private var runTab: some View {
        VStack(alignment: .leading, spacing: 14) {
            if render.info == nil {
                VStack(alignment: .leading, spacing: 12) {
                    Text("Сначала выберите видео.")
                        .font(.system(size: 15))
                        .foregroundStyle(Theme.textSecondary)
                    PrimaryButton(title: "Выбрать видео", icon: "video.badge.plus") { tab = 0 }
                }
                .themedCard()
            } else {
                summary

                ToggleRow(
                    title: "Применить цветокоррекцию",
                    caption: render.colorReady
                        ? "Цвет, чёткость и текстуры из вкладки «Цвет» применятся в том же проходе, без лишнего пережатия."
                        : "Сначала настройте цвет на вкладке «Цвет» (например, пресет «HDR-игра»).",
                    isOn: $render.applyColor,
                    disabled: !render.colorReady
                )

                action
            }

            status
        }
    }

    private var summary: some View {
        VStack(spacing: 0) {
            if let info = render.info {
                InfoRow(
                    label: "Частота кадров",
                    value: "\(Int(info.fps.rounded())) → \(render.smartPacing ? render.targetFPS : Int((info.fps * 2).rounded())) к/с"
                )
            }
            InfoRow(label: "Умный темп", value: render.smartPacing ? "Вкл" : "Выкл")
            InfoRow(
                label: "Нейро-улучшение",
                value: render.neuralEnabled ? "\(render.neuralModel.title), \(Int(render.neuralStrength))" : "Выкл"
            )
            InfoRow(label: "Цвет", value: render.applyColor ? "Вкл" : "Выкл")
            InfoRow(label: "Размытие движения", value: render.motionBlur == 0 ? "Выкл" : "\(Int(render.motionBlur))")
            InfoRow(label: "Резкость", value: render.sharpness == 0 ? "Выкл" : "\(Int(render.sharpness))")
            InfoRow(
                label: "Кодек",
                value: render.codec.usesBitrate ? "\(render.codec.title), \(Int(render.bitrate)) Мбит/с" : render.codec.title
            )
            InfoRow(label: "Размер файла", value: "≈ \(Int(render.estimatedSizeMB)) МБ", divider: false)
        }
        .themedCard()
    }

    @ViewBuilder
    private var action: some View {
        if case .rendering(let value) = render.state {
            VStack(alignment: .leading, spacing: 10) {
                ProgressView(value: value).tint(.white)
                Text("\(render.stageText) · \(Int(value * 100))% — не блокируй экран и не сворачивай приложение")
                    .font(.system(size: 12))
                    .foregroundStyle(Theme.textSecondary)
                PrimaryButton(title: "Отменить", icon: "xmark", dark: true) { render.cancel() }
            }
            .themedCard()
        } else {
            PrimaryButton(title: "Рендер", icon: "play.fill") { render.render() }
        }
    }

    @ViewBuilder
    private var status: some View {
        switch render.state {
        case .done(let url, let message):
            VStack(alignment: .leading, spacing: 12) {
                if let player = render.resultPlayer {
                    VideoPlayer(player: player)
                        .frame(height: 220)
                        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                }
                Label(message, systemImage: "checkmark.circle.fill")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(.green)
                ShareLink(item: url) {
                    PrimaryLabel(title: "Поделиться файлом", icon: "square.and.arrow.up", dark: true)
                }
            }
            .themedCard()
        case .failed(let message):
            if tab != 0 {
                Label(message, systemImage: "exclamationmark.triangle.fill")
                    .font(.system(size: 13))
                    .foregroundStyle(.red)
            }
        default:
            EmptyView()
        }
    }

    private func formatDuration(_ seconds: Double) -> String {
        let s = Int(seconds.rounded())
        return String(format: "%d:%02d", s / 60, s % 60)
    }
}
