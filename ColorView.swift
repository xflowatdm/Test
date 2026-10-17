import SwiftUI
import PhotosUI
import AVKit

// MARK: - Цвет

struct ColorScreen: View {
    @ObservedObject var color: ColorViewModel
    @ObservedObject var render: RenderViewModel
    let goToVideo: () -> Void

    @EnvironmentObject private var ui: AppUI
    @State private var referenceItem: PhotosPickerItem?

    var body: some View {
        List {
            if color.sourceURL == nil {
                Section {
                    VStack(spacing: 4) {
                        Text("Сначала выберите видео")
                            .font(.system(size: 16, weight: .semibold))
                            .foregroundStyle(Theme.text)
                        Text("Цвет настраивается для видео, выбранного на вкладке «Видео».")
                            .font(.system(size: 13.5))
                            .foregroundStyle(Theme.text2)
                            .multilineTextAlignment(.center)
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 28)
                    ActionRow(title: "К видео", icon: "play.rectangle") { goToVideo() }
                }
                .surfaceRow()
            } else {
                content
            }
        }
        .themedList()
        .animation(Theme.soft, value: color.match != nil)
        .animation(Theme.soft, value: color.isExporting)
        .navigationTitle("Цвет")
        .onChange(of: referenceItem) { _, item in
            guard let item else { return }
            Task {
                await color.loadReference(item)
                referenceItem = nil
            }
        }
    }

    @ViewBuilder
    private var content: some View {
        if let player = color.player {
            Section {
                MediaView(player: player) {
                    Button {
                        color.showOriginal.toggle()
                    } label: {
                        MediaCornerLabel(
                            title: "Оригинал",
                            icon: color.showOriginal ? "eye.fill" : "eye"
                        )
                        .opacity(color.showOriginal ? 1 : 0.85)
                    }
                    .buttonStyle(PressStyle())
                }
                .frame(height: 260)
                .listRowInsets(EdgeInsets())
                .listRowBackground(Color.clear)
                .rise(1)
            }
        }

        Section {
            SwitchRow(
                title: "Применять в рендере",
                sub: render.colorReady
                    ? "Цвет, чёткость и текстуры применятся в том же проходе, что и интерполяция, без лишнего пережатия."
                    : "Сначала настройте цвет ниже (например, пресет «HDR-игра»).",
                isOn: $render.applyColor,
                disabled: !render.colorReady
            )
        }
        .surfaceRow()
        .rise(2)

        Section {
            PhotosPicker(selection: $referenceItem, matching: .images) {
                HStack(spacing: 12) {
                    referenceThumb
                    ItemLabel(
                        title: color.referenceImage == nil ? "Загрузить скриншот-референс" : "Заменить референс",
                        sub: color.referenceImage == nil ? nil : "Референс загружен"
                    )
                    Spacer(minLength: 8)
                    Image(systemName: "chevron.right")
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(Theme.text3)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .disabled(color.isExporting)

            if color.referenceImage != nil {
                ActionRow(title: "Убрать референс", icon: "xmark") { color.clearReference() }
            }
            if color.match != nil {
                GradeSlider(title: "Сила совпадения", value: $color.params.matchStrength, range: 0...1, neutral: 1)
            }
        } header: {
            SectionLabel("Подбор по референсу")
        } footer: {
            Note(color.matchStatus.isEmpty
                 ? "Выберите скриншот кадра с нужной цветокоррекцией. Лучше брать кадр, похожий по сюжету и без интерфейса приложения. Приложение сравнит яркость и цвета и подберёт кривые."
                 : color.matchStatus)
        }
        .surfaceRow()
        .rise(3)

        Section {
            presetRow("HDR-игра", "Локальный контраст, резкие края, насыщенный цвет", .hdrGame)
            presetRow("Чёткая картинка", "Чище и чётче, цвет почти не меняется", .crisp)
            presetRow("Рисованный", "Однотонные текстуры заливаются цветом, края чёткие", .painted)
            Button {
                color.resetAll()
                ui.show("Настройки цвета сброшены")
            } label: {
                ItemLabel(title: "Сбросить настройки", sub: "Вернуть все ползунки в нейтральное положение")
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
        } header: {
            SectionLabel("Пресеты")
        }
        .disabled(color.isExporting)
        .surfaceRow()

        Section {
            ForEach(GradeGroup.allCases) { group in
                NavigationLink(value: VideoRoute.grade(group)) {
                    HStack {
                        ItemLabel(title: group.title)
                        Spacer(minLength: 8)
                        RollText(text: group.isNeutral(color.params) ? "Нейтрально" : "Изменено")
                            .font(.system(size: 16))
                            .foregroundStyle(Theme.text2)
                    }
                }
            }
        } header: {
            SectionLabel("Настройка")
        }
        .surfaceRow()

        exportSection
    }

    private var referenceThumb: some View {
        Group {
            if let image = color.referenceImage {
                Image(uiImage: image)
                    .resizable()
                    .scaledToFill()
            } else {
                Image(systemName: "photo.badge.plus")
                    .font(.system(size: 18, weight: .medium))
                    .foregroundStyle(Theme.text)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .background(Theme.surface2)
            }
        }
        .frame(width: 44, height: 44)
        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
    }

    private func presetRow(_ title: String, _ sub: String, _ preset: GradeParams) -> some View {
        Button {
            color.applyPreset(preset)
            ui.show("Пресет «\(title)» применён")
        } label: {
            ItemLabel(title: title, sub: sub)
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    // MARK: Экспорт

    private var exportSection: some View {
        Section {
            ValueRow(title: "Кодек", value: color.codec.title) {
                let codecs = VideoCodec.allCases
                ui.pick(
                    "Кодек",
                    options: codecs.map { SheetOption(title: $0.title) },
                    selected: codecs.firstIndex(of: color.codec)
                ) { color.codec = codecs[$0] }
            }
            .disabled(color.isExporting)

            if color.codec.usesBitrate {
                ValueRow(title: "Битрейт", value: "\(Int(color.bitrate)) Мбит/с") {
                    let values = BitratePresets.values(including: color.bitrate)
                    ui.pick(
                        "Битрейт",
                        options: values.map { SheetOption(title: "\(Int($0)) Мбит/с") },
                        selected: values.firstIndex(of: color.bitrate)
                    ) { color.bitrate = values[$0] }
                }
                .disabled(color.isExporting)
                GradeSlider(
                    title: "Точное значение, Мбит/с",
                    value: $color.bitrate,
                    range: 5...150,
                    neutral: 80,
                    format: "%.0f",
                    step: 5
                )
                .disabled(color.isExporting)
            }

            if color.isExporting {
                HStack(spacing: 12) {
                    ProgressRing(value: color.progress)
                        .frame(width: 22, height: 22)
                        .animation(.linear(duration: 0.2), value: color.progress)
                    ItemLabel(
                        title: "\(color.stage) · \(Int(color.progress * 100))%",
                        sub: "Не блокируй экран и не сворачивай приложение"
                    )
                }
                ActionRow(title: "Отменить", icon: "xmark") { color.cancel() }
            } else {
                ActionRow(title: "Применить и сохранить", icon: "checkmark") { color.export() }
            }

            if let message = color.resultMessage, let url = color.resultURL, !color.isExporting {
                VStack(alignment: .leading, spacing: 10) {
                    Text(message)
                        .font(.system(size: 13))
                        .foregroundStyle(Theme.text2)
                    ShareLink(item: url) {
                        Label("Поделиться файлом", systemImage: "square.and.arrow.up")
                            .font(.system(size: 16, weight: .semibold))
                            .frame(maxWidth: .infinity, minHeight: 36)
                    }
                    .buttonStyle(.glass)
                    .tint(Theme.text)
                }
                .padding(.vertical, 4)
            }
        } header: {
            SectionLabel("Экспорт только цвета")
        } footer: {
            Note("Сохраняет только цвет, без интерполяции и нейро-улучшения. Для полного результата используйте кнопку «Начать рендер».")
        }
        .surfaceRow()
    }
}

// MARK: - Группы ползунков

enum GradeGroup: String, CaseIterable, Identifiable, Hashable {
    case light
    case tone
    case details

    var id: String { rawValue }

    var title: String {
        switch self {
        case .light: return "Свет"
        case .tone: return "Цвет"
        case .details: return "Детали"
        }
    }

    func isNeutral(_ p: GradeParams) -> Bool {
        let n = GradeParams()
        switch self {
        case .light:
            return p.exposure == n.exposure && p.contrast == n.contrast && p.highlights == n.highlights
                && p.shadows == n.shadows && p.curve == n.curve
        case .tone:
            return p.warmth == n.warmth && p.tint == n.tint && p.saturation == n.saturation && p.vibrance == n.vibrance
        case .details:
            return p.flatten == n.flatten && p.denoise == n.denoise && p.clarity == n.clarity
                && p.sharpness == n.sharpness && p.vignette == n.vignette
        }
    }
}

struct GradeGroupScreen: View {
    let group: GradeGroup
    @ObservedObject var color: ColorViewModel

    var body: some View {
        List {
            Section {
                sliders
            } footer: {
                Note("Нажми на число справа от ползунка, чтобы вернуть его в исходное значение.")
            }
            .surfaceRow()
            .rise(1)
        }
        .themedList()
        .disabled(color.isExporting)
        .navigationTitle(group.title)
    }

    @ViewBuilder
    private var sliders: some View {
        switch group {
        case .light:
            GradeSlider(title: "Экспозиция", value: $color.params.exposure, range: -2...2, neutral: 0)
            GradeSlider(title: "Контраст", value: $color.params.contrast, range: 0.5...1.5, neutral: 1)
            GradeSlider(title: "Света (приглушить)", value: $color.params.highlights, range: 0...100, neutral: 0, format: "%.0f")
            GradeSlider(title: "Тени", value: $color.params.shadows, range: -100...100, neutral: 0, format: "%.0f")
            GradeSlider(title: "S-кривая (глубина)", value: $color.params.curve, range: 0...1, neutral: 0)
        case .tone:
            GradeSlider(title: "Теплота", value: $color.params.warmth, range: -100...100, neutral: 0, format: "%.0f")
            GradeSlider(title: "Оттенок", value: $color.params.tint, range: -100...100, neutral: 0, format: "%.0f")
            GradeSlider(title: "Насыщенность", value: $color.params.saturation, range: 0...2, neutral: 1)
            GradeSlider(title: "Живость", value: $color.params.vibrance, range: -1...1, neutral: 0)
        case .details:
            GradeSlider(title: "Кисть: заливка однотонных участков", value: $color.params.flatten, range: 0...1, neutral: 0)
            GradeSlider(title: "Сглаживание шума и текстур", value: $color.params.denoise, range: 0...1, neutral: 0)
            GradeSlider(title: "Чёткость (локальный контраст)", value: $color.params.clarity, range: 0...1, neutral: 0)
            GradeSlider(title: "Резкость", value: $color.params.sharpness, range: 0...2, neutral: 0)
            GradeSlider(title: "Виньетка", value: $color.params.vignette, range: 0...1, neutral: 0)
        }
    }
}
