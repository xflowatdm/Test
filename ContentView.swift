import SwiftUI
import PhotosUI
import AVKit

struct ContentView: View {
    @StateObject private var vm = RenderViewModel()
    @State private var pickerItem: PhotosPickerItem?

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 16) {
                    pickerSection
                    if vm.info != nil {
                        settingsSection
                        actionSection
                    }
                    statusSection
                }
                .padding()
            }
            .navigationTitle("Smooth Frames")
            .navigationBarTitleDisplayMode(.inline)
        }
        .onChange(of: pickerItem) { _, item in
            Task { await vm.load(item) }
        }
    }

    // MARK: Выбор видео

    private var pickerSection: some View {
        VStack(spacing: 12) {
            if let player = vm.player {
                VideoPlayer(player: player)
                    .aspectRatio(16.0 / 9.0, contentMode: .fit)
                    .clipShape(RoundedRectangle(cornerRadius: 14))
            }

            PhotosPicker(selection: $pickerItem, matching: .videos) {
                Label(vm.info == nil ? "Выбрать видео" : "Выбрать другое видео",
                      systemImage: "video.badge.plus")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .disabled(vm.isRendering || vm.isLoading)

            if vm.isLoading {
                HStack { ProgressView(); Text("Загружаю видео…").foregroundStyle(.secondary) }
            }

            if let info = vm.info {
                Text("\(info.width)×\(info.height) · \(Int(info.fps.rounded())) к/с · \(formatDuration(info.duration)) · \(String(format: "%.0f", info.bitrateMbps)) Мбит/с")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
        }
    }

    // MARK: Настройки

    private var settingsSection: some View {
        VStack(alignment: .leading, spacing: 18) {
            if let info = vm.info {
                HStack {
                    Text("Частота кадров")
                    Spacer()
                    Text("\(Int(info.fps.rounded())) → \(Int((info.fps * 2).rounded())) к/с")
                        .foregroundStyle(.secondary)
                }
            }

            Toggle(isOn: $vm.smoothing) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Сглаживание")
                    Text("Повышенное качество расчёта движения: меньше ряби и артефактов, но дольше рендер")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Text("Битрейт")
                    Spacer()
                    Text("\(Int(vm.bitrate)) Мбит/с").monospacedDigit()
                }
                Slider(value: $vm.bitrate, in: 5...150, step: 5)

                HStack(spacing: 8) {
                    ForEach([20.0, 40.0, 80.0, 120.0], id: \.self) { value in
                        Button("\(Int(value))") { vm.bitrate = value }
                            .buttonStyle(.bordered)
                            .tint(vm.bitrate == value ? .accentColor : .gray)
                    }
                }

                Text("≈ \(Int(vm.estimatedSizeMB)) МБ · кодек HEVC")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .padding()
        .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 14))
        .disabled(vm.isRendering)
    }

    // MARK: Кнопка рендера

    @ViewBuilder
    private var actionSection: some View {
        if vm.isRendering {
            Button(role: .destructive) { vm.cancel() } label: {
                Label("Отменить", systemImage: "xmark.circle")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.bordered)
            .controlSize(.large)
        } else {
            Button { vm.render() } label: {
                Label("Рендер", systemImage: "play.circle.fill")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .tint(.green)
        }
    }

    // MARK: Статус

    @ViewBuilder
    private var statusSection: some View {
        switch vm.state {
        case .idle:
            EmptyView()
        case .rendering(let value):
            VStack(spacing: 8) {
                ProgressView(value: value)
                Text("Обработка \(Int(value * 100))% — не блокируй экран и не сворачивай приложение")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }
        case .done(let url):
            VStack(spacing: 10) {
                Label("Готово! Видео сохранено в «Фото»", systemImage: "checkmark.circle.fill")
                    .foregroundStyle(.green)
                ShareLink(item: url) {
                    Label("Поделиться файлом", systemImage: "square.and.arrow.up")
                }
            }
        case .failed(let message):
            Label(message, systemImage: "exclamationmark.triangle.fill")
                .foregroundStyle(.red)
                .font(.footnote)
        }
    }

    private func formatDuration(_ seconds: Double) -> String {
        let s = Int(seconds.rounded())
        return String(format: "%d:%02d", s / 60, s % 60)
    }
}
