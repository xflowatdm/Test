import SwiftUI
import AVKit
import PhotosUI
import Photos

struct VideoFile: Transferable {
    let url: URL

    static var transferRepresentation: some TransferRepresentation {
        FileRepresentation(contentType: .movie) { video in
            SentTransferredFile(video.url)
        } importing: { received in
            let ext = received.file.pathExtension.isEmpty ? "mov" : received.file.pathExtension
            let dest = FileManager.default.temporaryDirectory
                .appendingPathComponent("src_\(UUID().uuidString).\(ext)")
            try FileManager.default.copyItem(at: received.file, to: dest)
            return VideoFile(url: dest)
        }
    }
}

struct VideoInfo {
    let width: Int
    let height: Int
    let fps: Double
    let duration: Double
    let bitrateMbps: Double
}

enum RenderState {
    case idle
    case rendering(Double)
    case done(URL, String)
    case failed(String)
}

@MainActor
final class RenderViewModel: ObservableObject {
    @Published var sourceURL: URL?
    @Published var info: VideoInfo?
    @Published var player: AVPlayer?
    @Published var isLoading = false
    @Published var smoothing = false
    @Published var motionBlur: Double = 0
    @Published var sharpness: Double = 0
    @Published var codec: VideoCodec = .hevc10
    @Published var resultPlayer: AVPlayer?
    @Published var bitrate: Double = 40
    @Published var state: RenderState = .idle
    @Published var stageText = ""
    @Published var previousCrash: String?

    private var task: Task<Void, Never>?

    init() {
        // Если прошлый рендер оборвался вылетом, здесь будет последний этап
        previousCrash = Breadcrumb.last
    }

    var isRendering: Bool {
        if case .rendering = state { return true }
        return false
    }

    var estimatedSizeMB: Double {
        guard let info else { return 0 }
        switch codec {
        case .hevc10, .hevc8:
            return bitrate * info.duration / 8
        case .proRes422:
            return proResMbps(base1080p30: 147) * info.duration / 8
        case .proRes422HQ:
            return proResMbps(base1080p30: 220) * info.duration / 8
        }
    }

    /// Ориентировочный поток ProRes: масштабируем от 1080p30 по числу пикселей и частоте кадров
    private func proResMbps(base1080p30: Double) -> Double {
        guard let info else { return 0 }
        let pixels = Double(info.width * info.height) / (1920.0 * 1080.0)
        return base1080p30 * pixels * (info.fps * 2 / 30)
    }

    func dismissCrashNote() {
        Breadcrumb.clear()
        previousCrash = nil
    }

    // MARK: Загрузка видео

    func load(_ item: PhotosPickerItem?) async {
        guard let item else { return }
        isLoading = true
        state = .idle
        resultPlayer = nil
        defer { isLoading = false }
        do {
            guard let file = try await item.loadTransferable(type: VideoFile.self) else {
                state = .failed("Не удалось загрузить видео.")
                return
            }
            let asset = AVURLAsset(url: file.url)
            guard let track = try await asset.loadTracks(withMediaType: .video).first else {
                state = .failed("В файле нет видео.")
                return
            }
            let size = try await track.load(.naturalSize)
            let fps = try await track.load(.nominalFrameRate)
            let rate = try await track.load(.estimatedDataRate)
            let duration = try await asset.load(.duration).seconds

            let sourceMbps = Double(rate) / 1_000_000
            let info = VideoInfo(
                width: Int(size.width), height: Int(size.height),
                fps: Double(fps), duration: duration, bitrateMbps: sourceMbps
            )
            self.info = info
            self.sourceURL = file.url
            self.player = AVPlayer(url: file.url)

            // Стартовый битрейт: ~1.5× от исходного, округлённо до 5
            let suggested = (sourceMbps * 1.5 / 5).rounded() * 5
            self.bitrate = min(150, max(10, suggested == 0 ? 40 : suggested))
        } catch {
            state = .failed(error.localizedDescription)
        }
    }

    // MARK: Рендер

    func render() {
        guard let source = sourceURL, !isRendering else { return }
        let settings = RenderSettings(bitrateMbps: bitrate, highQuality: smoothing, motionBlur: Int(motionBlur), sharpness: Int(sharpness), codec: codec)

        let documents = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        let stamp = DateFormatter()
        stamp.dateFormat = "yyyyMMdd_HHmmss"
        let output = documents.appendingPathComponent("Smooth_\(stamp.string(from: Date())).mov")

        player?.pause()
        previousCrash = nil
        resultPlayer = nil
        stageText = "Подготовка"
        state = .rendering(0)
        Breadcrumb.set("старт рендера")
        UIApplication.shared.isIdleTimerDisabled = true

        task = Task {
            defer { UIApplication.shared.isIdleTimerDisabled = false }
            do {
                try await FrameInterpolator.render(
                    source: source, output: output, settings: settings,
                    progress: { [weak self] value, stage in
                        Task { @MainActor in
                            guard let self, self.isRendering else { return }
                            self.state = .rendering(value)
                            self.stageText = stage
                        }
                    }
                )

                // Файл уже лежит в «Файлы» → Smooth Frames. Теперь пробуем положить в «Фото».
                stageText = "Сохранение в «Фото»"
                Breadcrumb.set("сохранение в Фото")
                var message = "Готово! Видео сохранено в «Фото» и в «Файлы» → Smooth Frames."
                do {
                    try await Self.saveToPhotos(output)
                } catch {
                    message = "Готово! Видео лежит в «Файлы» → Smooth Frames. В «Фото» сохранить не вышло: \(error.localizedDescription)"
                }
                Breadcrumb.clear()
                resultPlayer = AVPlayer(url: output)
                state = .done(output, message)
            } catch is CancellationError {
                Breadcrumb.clear()
                state = .idle
            } catch {
                Breadcrumb.clear()
                state = .failed(error.localizedDescription)
            }
        }
    }

    func cancel() {
        task?.cancel()
    }

    static func saveToPhotos(_ url: URL) async throws {
        guard Bundle.main.object(forInfoDictionaryKey: "NSPhotoLibraryAddUsageDescription") != nil else {
            throw RenderError.writer("в приложении нет разрешения на Фото")
        }
        let status = await PHPhotoLibrary.requestAuthorization(for: .addOnly)
        guard status == .authorized || status == .limited else {
            throw RenderError.writer("нет доступа к Фото, разреши его в Настройках")
        }
        try await PHPhotoLibrary.shared().performChanges {
            _ = PHAssetChangeRequest.creationRequestForAssetFromVideo(atFileURL: url)
        }
    }
}
