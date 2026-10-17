import SwiftUI
import AVKit
import PhotosUI
import Photos

struct VideoFile: Transferable {
    let url: URL
    /// Исходное имя файла (для подписи под видео)
    var name: String = ""

    static var transferRepresentation: some TransferRepresentation {
        FileRepresentation(contentType: .movie) { video in
            SentTransferredFile(video.url)
        } importing: { received in
            let ext = received.file.pathExtension.isEmpty ? "mov" : received.file.pathExtension
            let dest = FileManager.default.temporaryDirectory
                .appendingPathComponent("src_\(UUID().uuidString).\(ext)")
            try FileManager.default.copyItem(at: received.file, to: dest)
            return VideoFile(url: dest, name: received.file.lastPathComponent)
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

/// Настройки рендера по умолчанию (и после «Сбросить настройки рендера»)
enum RenderDefaults {
    static let targetFPS = 60
    static let motionBlur: Double = 50
    static let sharpness: Double = 50
    static let bitrate: Double = 150
}

/// Строка на вкладке «Задачи»
struct RenderJob: Identifiable {
    enum Status {
        case running(Double)
        case done
        case failed(String)
    }

    let id = UUID()
    var name: String
    var summary: String
    var url: URL?
    var status: Status
    var message: String?
}

@MainActor
final class RenderViewModel: ObservableObject {
    @Published var sourceURL: URL?
    @Published var info: VideoInfo?
    @Published var fileName = ""
    @Published var player: AVPlayer?
    @Published var isLoading = false
    @Published var loadProgress: Double = 0
    /// Растёт при каждой неудачной загрузке видео (для тряски и тоста)
    @Published var loadFailCount = 0
    @Published var smoothing = false
    @Published var motionBlur: Double = RenderDefaults.motionBlur
    @Published var sharpness: Double = RenderDefaults.sharpness
    @Published var codec: VideoCodec = .hevc10
    @Published var neuralEnabled = false
    @Published var neuralModel: NeuralModel = NeuralModel.available.first ?? .general
    @Published var neuralStrength: Double = 60
    @Published var applyColor = false
    @Published var smartPacing = true
    @Published var targetFPS = RenderDefaults.targetFPS
    @Published var colorReady = false
    /// Плеер раскрытой задачи на вкладке «Задачи»
    @Published var resultPlayer: AVPlayer?
    @Published var bitrate: Double = RenderDefaults.bitrate
    @Published var state: RenderState = .idle
    @Published var stageText = ""
    @Published var previousCrash: String?

    @Published var jobs: [RenderJob] = []
    @Published var expandedJob: UUID?
    /// Сколько рендеров завершилось, пока вкладка «Задачи» была закрыта
    @Published var unseenDone = 0
    @Published var renderStartedAt: Date?
    /// Растут при завершении и при ошибке рендера (для анимаций кнопки и тостов)
    @Published var finishCount = 0
    @Published var failCount = 0
    @Published var lastMessage = ""
    @Published var savedToPhotos = true

    private var task: Task<Void, Never>?
    private var loadObservation: NSKeyValueObservation?

    init() {
        // Если прошлый рендер оборвался вылетом, здесь будет последний этап
        previousCrash = Breadcrumb.last
        loadHistory()
    }

    var neuralAvailable: Bool { !NeuralModel.available.isEmpty }

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

    // MARK: Сводки для экранов

    /// Итоговая частота кадров
    var outputFPSText: String {
        if smartPacing { return "\(targetFPS) к/с" }
        guard let info else { return "×2" }
        return "\(Int((info.fps * 2).rounded())) к/с"
    }

    var smoothSummary: String {
        (smartPacing ? "\(targetFPS) к/с" : "×2") + (smoothing ? " + сглаж." : "")
    }

    var qualitySummary: String {
        codec.usesBitrate ? "\(codec.title), \(Int(bitrate)) Мб/с" : codec.title
    }

    var renderSummary: String {
        var parts = [outputFPSText, codec.title]
        if smoothing { parts.append("сглаживание") }
        if neuralEnabled { parts.append("нейро") }
        if applyColor { parts.append("цвет") }
        return parts.joined(separator: ", ")
    }

    var videoMeta: String {
        guard let info else { return "" }
        let s = Int(info.duration.rounded())
        return "\(info.width)×\(info.height), \(Int(info.fps.rounded())) к/с, "
            + String(format: "%02d:%02d", s / 60, s % 60)
            + String(format: " · %.0f Мбит/с", info.bitrateMbps)
    }

    func refreshColorState() {
        colorReady = GradeStore.isConfigured
        if !colorReady { applyColor = false }
    }

    func dismissCrashNote() {
        Breadcrumb.clear()
        previousCrash = nil
    }

    /// Возвращает настройки рендера к исходным
    func resetSettings() {
        smoothing = false
        motionBlur = RenderDefaults.motionBlur
        sharpness = RenderDefaults.sharpness
        codec = .hevc10
        neuralEnabled = false
        neuralModel = NeuralModel.available.first ?? .general
        neuralStrength = 60
        applyColor = false
        smartPacing = true
        targetFPS = RenderDefaults.targetFPS
        bitrate = RenderDefaults.bitrate
    }

    // MARK: Задачи

    func toggleExpand(_ job: RenderJob) {
        if expandedJob == job.id {
            expandedJob = nil
            resultPlayer?.pause()
            resultPlayer = nil
        } else if let url = job.url, case .done = job.status {
            expandedJob = job.id
            resultPlayer = AVPlayer(url: url)
        }
    }

    /// Готовые ролики из прошлых запусков (папка «Файлы» → Smooth Frames)
    private func loadHistory() {
        let documents = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        let keys: [URLResourceKey] = [.creationDateKey, .fileSizeKey]
        guard let files = try? FileManager.default.contentsOfDirectory(
            at: documents, includingPropertiesForKeys: keys
        ) else { return }

        let items: [(url: URL, date: Date, size: Int)] = files
            .filter { $0.lastPathComponent.hasPrefix("Smooth_") && $0.pathExtension.lowercased() == "mov" }
            .map { url -> (url: URL, date: Date, size: Int) in
                let values = try? url.resourceValues(forKeys: Set(keys))
                return (url: url, date: values?.creationDate ?? .distantPast, size: values?.fileSize ?? 0)
            }
            .sorted { $0.date > $1.date }

        jobs = items.map { item in
            let size = ByteCountFormatter.string(fromByteCount: Int64(item.size), countStyle: .file)
            return RenderJob(
                name: item.url.lastPathComponent,
                summary: "\(item.date.formatted(date: .abbreviated, time: .shortened)) · \(size)",
                url: item.url,
                status: .done
            )
        }
    }

    private func updateJob(_ id: UUID, _ change: (inout RenderJob) -> Void) {
        guard let index = jobs.firstIndex(where: { $0.id == id }) else { return }
        change(&jobs[index])
    }

    // MARK: Загрузка видео

    func load(_ item: PhotosPickerItem?) async {
        guard let item else { return }
        isLoading = true
        loadProgress = 0
        state = .idle
        defer {
            isLoading = false
            loadObservation?.invalidate()
            loadObservation = nil
        }
        do {
            guard let file = try await loadFile(item) else {
                failLoad("Не удалось загрузить видео.")
                return
            }
            let asset = AVURLAsset(url: file.url)
            guard let track = try await asset.loadTracks(withMediaType: .video).first else {
                failLoad("В файле нет видео.")
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
            loadProgress = 1
            self.info = info
            self.fileName = file.name.isEmpty ? file.url.lastPathComponent : file.name
            self.sourceURL = file.url
            self.player = AVPlayer(url: file.url)
        } catch {
            failLoad(error.localizedDescription)
        }
    }

    /// Загрузка из галереи с настоящим процентом готовности
    private func loadFile(_ item: PhotosPickerItem) async throws -> VideoFile? {
        try await withCheckedThrowingContinuation { continuation in
            let progress = item.loadTransferable(type: VideoFile.self) { result in
                continuation.resume(with: result)
            }
            loadObservation = progress.observe(\.fractionCompleted, options: [.initial, .new]) { [weak self] p, _ in
                let value = p.fractionCompleted
                Task { @MainActor in
                    guard let self, self.isLoading else { return }
                    self.loadProgress = max(self.loadProgress, min(value, 0.99))
                }
            }
        }
    }

    private func failLoad(_ message: String) {
        state = .failed(message)
        loadFailCount += 1
    }

    // MARK: Рендер

    func render() {
        guard let source = sourceURL, !isRendering else { return }
        let gradeSnapshot: GradeSnapshot? = (applyColor && GradeStore.isConfigured) ? GradeStore.snapshot() : nil
        let settings = RenderSettings(bitrateMbps: bitrate, highQuality: smoothing, motionBlur: Int(motionBlur), sharpness: Int(sharpness), codec: codec,
            neural: neuralEnabled ? neuralModel : nil, neuralStrength: neuralStrength,
            grade: gradeSnapshot, retimeFPS: smartPacing ? targetFPS : nil)

        let documents = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        let stamp = DateFormatter()
        stamp.dateFormat = "yyyyMMdd_HHmmss"
        let output = documents.appendingPathComponent("Smooth_\(stamp.string(from: Date())).mov")

        let job = RenderJob(name: fileName, summary: renderSummary, url: nil, status: .running(0))
        let jobID = job.id
        jobs.insert(job, at: 0)

        player?.pause()
        previousCrash = nil
        resultPlayer = nil
        expandedJob = nil
        stageText = "Подготовка"
        state = .rendering(0)
        renderStartedAt = Date()
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
                            self.updateJob(jobID) { $0.status = .running(value) }
                        }
                    }
                )

                // Файл уже лежит в «Файлы» → Smooth Frames. Теперь пробуем положить в «Фото».
                stageText = "Сохранение в «Фото»"
                Breadcrumb.set("сохранение в Фото")
                var message = "Готово! Видео сохранено в «Фото» и в «Файлы» → Smooth Frames."
                savedToPhotos = true
                do {
                    try await Self.saveToPhotos(output)
                } catch {
                    savedToPhotos = false
                    message = "Готово! Видео лежит в «Файлы» → Smooth Frames. В «Фото» сохранить не вышло: \(error.localizedDescription)"
                }
                Breadcrumb.clear()
                updateJob(jobID) {
                    $0.status = .done
                    $0.url = output
                    $0.message = message
                }
                expandedJob = jobID
                resultPlayer = AVPlayer(url: output)
                state = .done(output, message)
                lastMessage = message
                unseenDone += 1
                finishCount += 1
            } catch is CancellationError {
                Breadcrumb.clear()
                jobs.removeAll { $0.id == jobID }
                state = .idle
            } catch {
                Breadcrumb.clear()
                updateJob(jobID) { $0.status = .failed(error.localizedDescription) }
                state = .failed(error.localizedDescription)
                lastMessage = error.localizedDescription
                failCount += 1
            }
            renderStartedAt = nil
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
