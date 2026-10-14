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
                    crashSection
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

    // MARK: Прошлый вылет

    @ViewBuilder
    private var crashSection: some View {
        if let crash = vm.previousCrash {
            VStack(alignment: .leading, spacing: 8) {
                Label("Прошлый рендер оборвался вылетом", systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange)
                Text("Последний этап: \(crash)")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                Button("Скрыть") { vm.dismissCrashNote() }
                    .font(.footnote)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding()
            .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 14))
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
                    Text("Сглаживание (экспериментально)")
                    Text("Режим повышенного качества. На резких поворотах камеры может рвать картинку — тогда выключи")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Text("Размытие движения")
                    Spacer()
                    Text(vm.motionBlur == 0 ? "Выкл" : "\(Int(vm.motionBlur))").monospacedDigit()
                }
                Slider(value: $vm.motionBlur, in: 0...100, step: 5)

                HStack(spacing: 8) {
                    ForEach([0.0, 25.0, 50.0, 75.0], id: \.self) { value in
                        Button(value == 0 ? "Выкл" : "\(Int(value))") { vm.motionBlur = value }
                            .buttonStyle(.bordered)
                            .tint(vm.motionBlur == value ? .accentColor : .gray)
                    }
                }

                Text("Имитирует выдержку камеры: быстрые объекты слегка смазываются. Рендер идёт заметно дольше.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Text("Резкость достроенных кадров")
                    Spacer()
                    Text(vm.sharpness == 0 ? "Выкл" : "\(Int(vm.sharpness))").monospacedDigit()
                }
                Slider(value: $vm.sharpness, in: 0...100, step: 5)

                HStack(spacing: 8) {
                    ForEach([0.0, 25.0, 50.0, 75.0], id: \.self) { value in
                        Button(value == 0 ? "Выкл" : "\(Int(value))") { vm.sharpness = value }
                            .buttonStyle(.bordered)
                            .tint(vm.sharpness == value ? .accentColor : .gray)
                    }
                }

                Text("Подтягивает чёткость промежуточных кадров, они обычно мягче оригинальных. Исходные кадры не меняются.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
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
                Text("\(vm.stageText) · \(Int(value * 100))% — не блокируй экран и не сворачивай приложение")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }
        case .done(let url, let message):
            VStack(spacing: 10) {
                if let player = vm.resultPlayer {
                    VideoPlayer(player: player)
                        .frame(height: 220)
                        .clipShape(RoundedRectangle(cornerRadius: 14))
                }
                Label(message, systemImage: "checkmark.circle.fill")
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
