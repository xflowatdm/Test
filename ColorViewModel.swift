import SwiftUI
import AVKit
import PhotosUI

@MainActor
final class ColorViewModel: ObservableObject {
    @Published var sourceURL: URL?
    @Published var player: AVPlayer?
    @Published var isLoading = false

    @Published var referenceImage: UIImage?
    @Published var params = GradeParams()
    @Published var match: MatchCurve?
    @Published var matchStatus = ""
    @Published var showOriginal = false

    @Published var codec: VideoCodec = .hevc10
    @Published var bitrate: Double = 80

    @Published var isExporting = false
    @Published var progress: Double = 0
    @Published var stage = ""
    @Published var resultURL: URL?
    @Published var resultMessage: String?
    @Published var errorMessage: String?

    /// Из этого хранилища читает плеер при показе кадров
    let previewBox = GradeBox()

    private var sourceHistogram: ColorMatcher.Histogram?
    private var referenceHistogram: ColorMatcher.Histogram?
    private var task: Task<Void, Never>?

    // MARK: Загрузка видео

    func loadVideo(_ item: PhotosPickerItem?) async {
        guard let item else { return }
        isLoading = true
        errorMessage = nil
        resultMessage = nil
        resultURL = nil
        defer { isLoading = false }
        do {
            guard let file = try await item.loadTransferable(type: VideoFile.self) else {
                errorMessage = "Не удалось загрузить видео."
                return
            }
            sourceURL = file.url
            buildPlayer(for: file.url)

            matchStatus = "Анализирую кадры видео…"
            sourceHistogram = await ColorMatcher.histogram(from: AVURLAsset(url: file.url))
            matchStatus = ""
            recomputeMatch()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    /// Видео выбирается один раз в разделе «Видео» и приходит сюда готовым файлом
    func setSource(_ url: URL?) async {
        guard let url else { return }
        errorMessage = nil
        resultMessage = nil
        resultURL = nil
        sourceURL = url
        buildPlayer(for: url)

        matchStatus = "Анализирую кадры видео…"
        sourceHistogram = await ColorMatcher.histogram(from: AVURLAsset(url: url))
        matchStatus = ""
        recomputeMatch()
    }

    private func buildPlayer(for url: URL) {
        let asset = AVURLAsset(url: url)
        let item = AVPlayerItem(asset: asset)
        let box = previewBox
        let composition = AVMutableVideoComposition(asset: asset, applyingCIFiltersWithHandler: { request in
            let (p, m) = box.get()
            let out = ColorGrader.apply(to: request.sourceImage, params: p, match: m)
            request.finish(with: out, context: ColorGrader.context)
        })
        item.videoComposition = composition
        player = AVPlayer(playerItem: item)
        pushPreview()
    }

    // MARK: Референс

    func loadReference(_ item: PhotosPickerItem?) async {
        guard let item else { return }
        errorMessage = nil
        do {
            guard
                let data = try await item.loadTransferable(type: Data.self),
                let image = UIImage(data: data),
                let cg = image.cgImage,
                let hist = ColorMatcher.histogram(of: cg)
            else {
                errorMessage = "Не удалось прочитать картинку-референс."
                return
            }
            referenceImage = image
            referenceHistogram = hist
            recomputeMatch()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func recomputeMatch() {
        guard let s = sourceHistogram, let r = referenceHistogram else { return }
        match = ColorMatcher.fit(source: s, reference: r)
        params.matchStrength = 1
        matchStatus = "Цвета подобраны по референсу. Силу можно менять, а сверху настроить вручную."
    }

    func clearReference() {
        referenceImage = nil
        referenceHistogram = nil
        match = nil
        matchStatus = ""
    }

    func resetAll() {
        let strength = params.matchStrength
        params = GradeParams()
        params.matchStrength = strength
    }

    // MARK: Просмотр

    func applyPreset(_ preset: GradeParams) {
        var p = preset
        p.matchStrength = params.matchStrength
        params = p
    }

    func pushPreview() {
        // настоящие значения (без режима «показать оригинал») — для вкладки «Рендер»
        GradeStore.box.set(params: params, match: match)
        if showOriginal {
            previewBox.set(params: GradeParams(), match: nil)
        } else {
            previewBox.set(params: params, match: match)
        }
        guard let p = player else { return }
        p.seek(to: p.currentTime(), toleranceBefore: .zero, toleranceAfter: .zero)
    }

    // MARK: Экспорт

    func export() {
        guard let source = sourceURL, !isExporting else { return }

        let box = GradeBox()
        box.set(params: params, match: match)

        let documents = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        let stamp = DateFormatter()
        stamp.dateFormat = "yyyyMMdd_HHmmss"
        let output = documents.appendingPathComponent("Color_\(stamp.string(from: Date())).mov")

        player?.pause()
        errorMessage = nil
        resultMessage = nil
        resultURL = nil
        progress = 0
        stage = "Подготовка"
        isExporting = true
        UIApplication.shared.isIdleTimerDisabled = true

        let codec = self.codec
        let bitrate = self.bitrate

        task = Task {
            defer {
                UIApplication.shared.isIdleTimerDisabled = false
                isExporting = false
            }
            do {
                try await ColorExporter.export(
                    source: source, output: output, grade: box, codec: codec, bitrateMbps: bitrate,
                    progress: { [weak self] value, stage in
                        Task { @MainActor in
                            guard let self, self.isExporting else { return }
                            self.progress = value
                            self.stage = stage
                        }
                    }
                )
                stage = "Сохранение в «Фото»"
                var message = "Готово! Видео сохранено в «Фото» и в «Файлы» → Smooth Frames."
                do {
                    try await RenderViewModel.saveToPhotos(output)
                } catch {
                    message = "Готово! Видео лежит в «Файлы» → Smooth Frames. В «Фото» сохранить не вышло: \(error.localizedDescription)"
                }
                Breadcrumb.clear()
                resultURL = output
                resultMessage = message
            } catch is CancellationError {
                Breadcrumb.clear()
            } catch {
                Breadcrumb.clear()
                errorMessage = error.localizedDescription
            }
        }
    }

    func cancel() {
        task?.cancel()
    }
}
