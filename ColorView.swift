import SwiftUI
import PhotosUI
import AVKit

struct ColorView: View {
    @StateObject private var vm = ColorViewModel()
    @State private var videoItem: PhotosPickerItem?
    @State private var referenceItem: PhotosPickerItem?

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 16) {
                    videoSection
                    if vm.sourceURL != nil {
                        referenceSection
                        manualSection
                        exportSection
                    }
                    messages
                }
                .padding()
            }
            .navigationTitle("Цветокоррекция")
            .navigationBarTitleDisplayMode(.inline)
        }
        .onChange(of: videoItem) { _, item in Task { await vm.loadVideo(item) } }
        .onChange(of: referenceItem) { _, item in Task { await vm.loadReference(item) } }
        .onChange(of: vm.params) { _, _ in vm.pushPreview() }
        .onChange(of: vm.match) { _, _ in vm.pushPreview() }
        .onChange(of: vm.showOriginal) { _, _ in vm.pushPreview() }
    }

    // MARK: Видео

    private var videoSection: some View {
        VStack(spacing: 12) {
            if let player = vm.player {
                VideoPlayer(player: player)
                    .aspectRatio(16.0 / 9.0, contentMode: .fit)
                    .clipShape(RoundedRectangle(cornerRadius: 14))

                Toggle("Показать оригинал", isOn: $vm.showOriginal)
                    .font(.subheadline)
            }

            PhotosPicker(selection: $videoItem, matching: .videos) {
                Label(vm.sourceURL == nil ? "Выбрать видео" : "Выбрать другое видео",
                      systemImage: "video.badge.plus")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .disabled(vm.isExporting || vm.isLoading)

            if vm.isLoading {
                HStack { ProgressView(); Text("Загружаю видео…").foregroundStyle(.secondary) }
            }
        }
    }

    // MARK: Референс

    private var referenceSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Подбор по референсу").font(.headline)

            if let image = vm.referenceImage {
                HStack(spacing: 12) {
                    Image(uiImage: image)
                        .resizable()
                        .scaledToFill()
                        .frame(width: 90, height: 90)
                        .clipShape(RoundedRectangle(cornerRadius: 10))
                    VStack(alignment: .leading, spacing: 6) {
                        Text("Референс загружен")
                        Button("Убрать", role: .destructive) { vm.clearReference() }
                            .font(.footnote)
                    }
                }
            }

            PhotosPicker(selection: $referenceItem, matching: .images) {
                Label(vm.referenceImage == nil ? "Загрузить скриншот-референс" : "Заменить референс",
                      systemImage: "photo.badge.plus")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.bordered)
            .controlSize(.large)
            .disabled(vm.isExporting)

            if vm.match != nil {
                GradeSlider(title: "Сила совпадения", value: $vm.params.matchStrength,
                            range: 0...1, neutral: 1, format: "%.2f")
            }

            Text(vm.matchStatus.isEmpty
                 ? "Выбери скриншот кадра с нужной цветокоррекцией. Лучше брать кадр, похожий по сюжету и без интерфейса приложения. Приложение сравнит яркость и цвета и подберёт кривые."
                 : vm.matchStatus)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding()
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 14))
    }

    // MARK: Ручная настройка

    private var manualSection: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Text("Ручная настройка").font(.headline)
                Spacer()
                Button("Сбросить") { vm.resetAll() }.font(.footnote)
            }

            HStack(spacing: 8) {
                Button("HDR-игра") { vm.applyPreset(.hdrGame) }
                    .buttonStyle(.bordered)
                Button("Чёткая картинка") { vm.applyPreset(.crisp) }
                    .buttonStyle(.bordered)
            }

            Text("Свет").font(.subheadline).foregroundStyle(.secondary)
            GradeSlider(title: "Экспозиция", value: $vm.params.exposure, range: -2...2, neutral: 0)
            GradeSlider(title: "Контраст", value: $vm.params.contrast, range: 0.5...1.5, neutral: 1)
            GradeSlider(title: "Света (приглушить)", value: $vm.params.highlights, range: 0...100, neutral: 0, format: "%.0f")
            GradeSlider(title: "Тени", value: $vm.params.shadows, range: -100...100, neutral: 0, format: "%.0f")

            Text("Цвет").font(.subheadline).foregroundStyle(.secondary)
            GradeSlider(title: "Теплота", value: $vm.params.warmth, range: -100...100, neutral: 0, format: "%.0f")
            GradeSlider(title: "Оттенок", value: $vm.params.tint, range: -100...100, neutral: 0, format: "%.0f")
            GradeSlider(title: "Насыщенность", value: $vm.params.saturation, range: 0...2, neutral: 1)
            GradeSlider(title: "Живость", value: $vm.params.vibrance, range: -1...1, neutral: 0)

            Text("Чёткость и текстуры").font(.subheadline).foregroundStyle(.secondary)
            GradeSlider(title: "Сглаживание шума и текстур", value: $vm.params.denoise, range: 0...1, neutral: 0)
            GradeSlider(title: "Чёткость (локальный контраст)", value: $vm.params.clarity, range: 0...1, neutral: 0)
            GradeSlider(title: "S-кривая (глубина)", value: $vm.params.curve, range: 0...1, neutral: 0)

            Text("Детали").font(.subheadline).foregroundStyle(.secondary)
            GradeSlider(title: "Резкость", value: $vm.params.sharpness, range: 0...2, neutral: 0)
            GradeSlider(title: "Виньетка", value: $vm.params.vignette, range: 0...1, neutral: 0)

            Text("Нажми на число справа от ползунка, чтобы вернуть его в исходное значение.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding()
        .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 14))
        .disabled(vm.isExporting)
    }

    // MARK: Экспорт

    private var exportSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Сохранение").font(.headline)

            HStack {
                Text("Кодек")
                Spacer()
                Picker("Кодек", selection: $vm.codec) {
                    ForEach(VideoCodec.allCases) { codec in
                        Text(codec.title).tag(codec)
                    }
                }
                .pickerStyle(.menu)
            }

            if vm.codec.usesBitrate {
                HStack {
                    Text("Битрейт")
                    Spacer()
                    Text("\(Int(vm.bitrate)) Мбит/с").monospacedDigit()
                }
                Slider(value: $vm.bitrate, in: 5...150, step: 5)
            }

            if vm.isExporting {
                VStack(spacing: 8) {
                    ProgressView(value: vm.progress)
                    Text("\(vm.stage) · \(Int(vm.progress * 100))% — не блокируй экран и не сворачивай приложение")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                    Button(role: .destructive) { vm.cancel() } label: {
                        Label("Отменить", systemImage: "xmark.circle").frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.large)
                }
            } else {
                Button { vm.export() } label: {
                    Label("Применить и сохранить", systemImage: "checkmark.circle.fill")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .tint(.green)
            }
        }
        .padding()
        .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 14))
    }

    // MARK: Сообщения

    @ViewBuilder
    private var messages: some View {
        if let message = vm.resultMessage, let url = vm.resultURL {
            VStack(spacing: 10) {
                Label(message, systemImage: "checkmark.circle.fill")
                    .foregroundStyle(.green)
                ShareLink(item: url) {
                    Label("Поделиться файлом", systemImage: "square.and.arrow.up")
                }
            }
        }
        if let error = vm.errorMessage {
            Label(error, systemImage: "exclamationmark.triangle.fill")
                .foregroundStyle(.red)
                .font(.footnote)
        }
    }
}

/// Ползунок с названием и значением. Нажатие на значение сбрасывает ползунок.
struct GradeSlider: View {
    let title: String
    @Binding var value: Double
    let range: ClosedRange<Double>
    let neutral: Double
    var format: String = "%.2f"

    var body: some View {
        VStack(spacing: 2) {
            HStack {
                Text(title)
                Spacer()
                Button(String(format: format, value)) { value = neutral }
                    .buttonStyle(.plain)
                    .monospacedDigit()
                    .foregroundStyle(abs(value - neutral) < 0.0001 ? Color.secondary : Color.accentColor)
            }
            Slider(value: $value, in: range)
        }
    }
}
