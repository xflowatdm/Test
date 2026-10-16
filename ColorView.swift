import SwiftUI
import PhotosUI
import AVKit

// MARK: - Цвет

struct ColorScreen: View {
    @ObservedObject var color: ColorViewModel
    @ObservedObject var render: RenderViewModel
    let goToRender: () -> Void

    @State private var tab = 0
    @State private var referenceItem: PhotosPickerItem?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                SectionHeader(title: "Цвет", subtitle: "Подбор по референсу и ручная настройка")

                if color.sourceURL == nil {
                    VStack(alignment: .leading, spacing: 12) {
                        Text("Сначала выберите видео на вкладке «Рендер».")
                            .font(.system(size: 15))
                            .foregroundStyle(Theme.textSecondary)
                        PrimaryButton(title: "Выбрать видео", icon: "video.badge.plus") { goToRender() }
                    }
                    .themedCard()
                } else {
                    preview
                    PillTabs(titles: ["Подбор", "Свет", "Цвет", "Детали", "Экспорт"], selection: $tab)
                    tabContent
                }

                messages
            }
            .padding(.horizontal, 16)
            .padding(.top, 8)
            .padding(.bottom, 24)
        }
        .onChange(of: referenceItem) { _, item in Task { await color.loadReference(item) } }
        .onChange(of: color.params) { _, _ in color.pushPreview() }
        .onChange(of: color.match) { _, _ in color.pushPreview() }
        .onChange(of: color.showOriginal) { _, _ in color.pushPreview() }
    }

    // MARK: Просмотр

    private var preview: some View {
        VStack(spacing: 10) {
            if let player = color.player {
                VideoPlayer(player: player)
                    .aspectRatio(16.0 / 9.0, contentMode: .fit)
                    .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
            }
            ToggleRow(title: "Показать оригинал", isOn: $color.showOriginal)
        }
    }

    @ViewBuilder
    private var tabContent: some View {
        switch tab {
        case 0:
            matching
        case 1:
            light
        case 2:
            colors
        case 3:
            details
        default:
            export
        }
    }

    // MARK: Подбор

    private var matching: some View {
        VStack(alignment: .leading, spacing: 10) {
            if let image = color.referenceImage {
                HStack(spacing: 12) {
                    Image(uiImage: image)
                        .resizable()
                        .scaledToFill()
                        .frame(width: 84, height: 84)
                        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                    VStack(alignment: .leading, spacing: 6) {
                        Text("Референс загружен")
                            .font(.system(size: 15, weight: .semibold))
                            .foregroundStyle(.white)
                        Button("Убрать") { color.clearReference() }
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundStyle(.red)
                    }
                    Spacer(minLength: 0)
                }
                .themedCard()
            }

            PhotosPicker(selection: $referenceItem, matching: .images) {
                PrimaryLabel(
                    title: color.referenceImage == nil ? "Загрузить скриншот-референс" : "Заменить референс",
                    icon: "photo.badge.plus"
                )
            }
            .disabled(color.isExporting)

            if color.match != nil {
                GradeSlider(title: "Сила совпадения", value: $color.params.matchStrength, range: 0...1, neutral: 1)
                    .themedCard()
            }

            Text(color.matchStatus.isEmpty
                 ? "Выберите скриншот кадра с нужной цветокоррекцией. Лучше брать кадр, похожий по сюжету и без интерфейса приложения. Приложение сравнит яркость и цвета и подберёт кривые."
                 : color.matchStatus)
                .font(.system(size: 12))
                .foregroundStyle(Theme.textSecondary)

            SmallCaption(text: "Пресеты")
            SelectRow(title: "HDR-игра", subtitle: "Локальный контраст, резкие края, насыщенный цвет", selected: false) {
                color.applyPreset(.hdrGame)
            }
            SelectRow(title: "Чёткая картинка", subtitle: "Чище и чётче, цвет почти не меняется", selected: false) {
                color.applyPreset(.crisp)
            }
            SelectRow(title: "Сбросить настройки", subtitle: "Вернуть все ползунки в нейтральное положение", selected: false) {
                color.resetAll()
            }

            ToggleRow(
                title: "Применять в рендере",
                caption: "Включает этот цвет на вкладке «Рендер» (один проход вместе с интерполяцией).",
                isOn: $render.applyColor
            )
        }
    }

    // MARK: Ползунки

    private var light: some View {
        VStack(alignment: .leading, spacing: 16) {
            GradeSlider(title: "Экспозиция", value: $color.params.exposure, range: -2...2, neutral: 0)
            GradeSlider(title: "Контраст", value: $color.params.contrast, range: 0.5...1.5, neutral: 1)
            GradeSlider(title: "Света (приглушить)", value: $color.params.highlights, range: 0...100, neutral: 0, format: "%.0f")
            GradeSlider(title: "Тени", value: $color.params.shadows, range: -100...100, neutral: 0, format: "%.0f")
            GradeSlider(title: "S-кривая (глубина)", value: $color.params.curve, range: 0...1, neutral: 0)
            hint
        }
        .themedCard()
        .disabled(color.isExporting)
    }

    private var colors: some View {
        VStack(alignment: .leading, spacing: 16) {
            GradeSlider(title: "Теплота", value: $color.params.warmth, range: -100...100, neutral: 0, format: "%.0f")
            GradeSlider(title: "Оттенок", value: $color.params.tint, range: -100...100, neutral: 0, format: "%.0f")
            GradeSlider(title: "Насыщенность", value: $color.params.saturation, range: 0...2, neutral: 1)
            GradeSlider(title: "Живость", value: $color.params.vibrance, range: -1...1, neutral: 0)
            hint
        }
        .themedCard()
        .disabled(color.isExporting)
    }

    private var details: some View {
        VStack(alignment: .leading, spacing: 16) {
            GradeSlider(title: "Сглаживание шума и текстур", value: $color.params.denoise, range: 0...1, neutral: 0)
            GradeSlider(title: "Чёткость (локальный контраст)", value: $color.params.clarity, range: 0...1, neutral: 0)
            GradeSlider(title: "Резкость", value: $color.params.sharpness, range: 0...2, neutral: 0)
            GradeSlider(title: "Виньетка", value: $color.params.vignette, range: 0...1, neutral: 0)
            hint
        }
        .themedCard()
        .disabled(color.isExporting)
    }

    private var hint: some View {
        Text("Нажми на число справа от ползунка, чтобы вернуть его в исходное значение.")
            .font(.system(size: 12))
            .foregroundStyle(Theme.textSecondary)
    }

    // MARK: Экспорт

    private var export: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Сохранить только цвет, без интерполяции и нейро-улучшения. Для полного результата используйте вкладку «Рендер».")
                .font(.system(size: 12))
                .foregroundStyle(Theme.textSecondary)

            ForEach(VideoCodec.allCases) { codec in
                SelectRow(title: codec.title, selected: color.codec == codec) {
                    color.codec = codec
                }
            }

            if color.codec.usesBitrate {
                GradeSlider(
                    title: "Битрейт, Мбит/с",
                    value: $color.bitrate,
                    range: 5...150,
                    neutral: 80,
                    format: "%.0f",
                    step: 5
                )
                .themedCard()
            }

            if color.isExporting {
                VStack(alignment: .leading, spacing: 10) {
                    ProgressView(value: color.progress).tint(.white)
                    Text("\(color.stage) · \(Int(color.progress * 100))% — не блокируй экран и не сворачивай приложение")
                        .font(.system(size: 12))
                        .foregroundStyle(Theme.textSecondary)
                    PrimaryButton(title: "Отменить", icon: "xmark", dark: true) { color.cancel() }
                }
                .themedCard()
            } else {
                PrimaryButton(title: "Применить и сохранить", icon: "checkmark") { color.export() }
            }
        }
    }

    // MARK: Сообщения

    @ViewBuilder
    private var messages: some View {
        if let message = color.resultMessage, let url = color.resultURL {
            VStack(alignment: .leading, spacing: 10) {
                Label(message, systemImage: "checkmark.circle.fill")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(.green)
                ShareLink(item: url) {
                    PrimaryLabel(title: "Поделиться файлом", icon: "square.and.arrow.up", dark: true)
                }
            }
            .themedCard()
        }
        if let error = color.errorMessage {
            Label(error, systemImage: "exclamationmark.triangle.fill")
                .font(.system(size: 13))
                .foregroundStyle(.red)
        }
    }
}
