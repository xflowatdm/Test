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
    case done(URL)
    case failed(String)
}

@MainActor
final class RenderViewModel: ObservableObject {
    @Published var sourceURL: URL?
    @Published var info: VideoInfo?
    @Published var player: AVPlayer?
    @Published var isLoading = false
    @Published var smoothing = true
    @Published var bitrate: Double = 40
    @Published var state: RenderState = .idle

    private var task: Task<Void, Never>?

    var isRendering: Bool {
        if case .rendering = state { return true }
        return false
    }

    var estimatedSizeMB: Double {
        guard let info else { return 0 }
        return bitrate * info.duration / 8
    }

    // MARK: Загрузка видео

    func load(_ item: PhotosPickerItem?) async {
        guard let item else { return }
        isLoading = true
        state = .idle
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
        let settings = RenderSettings(bitrateMbps: bitrate, highQuality: smoothing)
        let output = FileManager.default.temporaryDirectory
            .appendingPathComponent("smooth_\(UUID().uuidString).mov")

        player?.pause()
        state = .rendering(0)
        UIApplication.shared.isIdleTimerDisabled = true

        task = Task {
            defer { UIApplication.shared.isIdleTimerDisabled = false }
            do {
                try await FrameInterpolator.render(
                    source: source, output: output, settings: settings,
                    progress: { [weak self] value in
                        Task { @MainActor in
                            if self?.isRendering == true { self?.state = .rendering(value) }
                        }
                    }
                )
                try await Self.saveToPhotos(output)
                state = .done(output)
            } catch is CancellationError {
                state = .idle
            } catch {
                state = .failed(error.localizedDescription)
            }
        }
    }

    func cancel() {
        task?.cancel()
    }

    private static func saveToPhotos(_ url: URL) async throws {
        let status = await PHPhotoLibrary.requestAuthorization(for: .addOnly)
        guard status == .authorized || status == .limited else {
            throw RenderError.writer("Нет доступа к Фото. Разреши добавление в Настройках.")
        }
        try await PHPhotoLibrary.shared().performChanges {
            _ = PHAssetChangeRequest.creationRequestForAssetFromVideo(atFileURL: url)
        }
    }
}
