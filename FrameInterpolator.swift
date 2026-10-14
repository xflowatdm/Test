import AVFoundation
import VideoToolbox
import CoreVideo

struct RenderSettings {
    /// Битрейт результата в Мбит/с
    var bitrateMbps: Double
    /// Режим повышенного качества интерполяции («сглаживание»)
    var highQuality: Bool
}

enum RenderError: LocalizedError {
    case unsupportedDevice
    case noVideoTrack
    case unsupportedSize(Int, Int)
    case configurationFailed
    case frameCreationFailed
    case reader(String)
    case writer(String)

    var errorDescription: String? {
        switch self {
        case .unsupportedDevice:
            return "Это устройство не поддерживает интерполяцию кадров (нужен iOS 26 и актуальный iPhone)."
        case .noVideoTrack:
            return "В файле не найдена видеодорожка."
        case .unsupportedSize(let w, let h):
            return "Разрешение \(w)×\(h) слишком большое. Максимум для iPhone — 4096×2160."
        case .configurationFailed:
            return "Не удалось настроить обработчик кадров."
        case .frameCreationFailed:
            return "Не удалось подготовить кадр для обработки."
        case .reader(let m):
            return "Ошибка чтения видео: \(m)"
        case .writer(let m):
            return "Ошибка записи видео: \(m)"
        }
    }
}

enum FrameInterpolator {

    private static let pixelFormat = kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange

    /// Читает видео, достраивает по одному промежуточному кадру между каждой парой
    /// соседних кадров (60 → 120 к/с), кодирует в HEVC с заданным битрейтом.
    /// Звук копируется без перекодирования.
    static func render(
        source: URL,
        output: URL,
        settings: RenderSettings,
        progress: @escaping @Sendable (Double) -> Void
    ) async throws {

        guard VTFrameRateConversionConfiguration.isSupported else {
            throw RenderError.unsupportedDevice
        }

        // MARK: Исходник
        let asset = AVURLAsset(url: source)
        guard let videoTrack = try await asset.loadTracks(withMediaType: .video).first else {
            throw RenderError.noVideoTrack
        }
        let naturalSize = try await videoTrack.load(.naturalSize)
        let transform = try await videoTrack.load(.preferredTransform)
        let nominalFPS = try await videoTrack.load(.nominalFrameRate)
        let duration = try await asset.load(.duration)
        let videoFormats = try await videoTrack.load(.formatDescriptions)

        let width = Int(naturalSize.width.rounded())
        let height = Int(naturalSize.height.rounded())
        guard width <= 4096, height <= 2160 else {
            throw RenderError.unsupportedSize(width, height)
        }

        let audioTrack = try await asset.loadTracks(withMediaType: .audio).first
        let audioFormat = try await audioTrack?.load(.formatDescriptions).first

        let sourceFPS = nominalFPS > 0 ? Double(nominalFPS) : 60
        let outputFPS = sourceFPS * 2
        let totalFrames = max(1, duration.seconds * sourceFPS)

        // MARK: Reader
        let reader = try AVAssetReader(asset: asset)
        let videoOut = AVAssetReaderTrackOutput(track: videoTrack, outputSettings: [
            kCVPixelBufferPixelFormatTypeKey as String: pixelFormat,
            kCVPixelBufferIOSurfacePropertiesKey as String: [String: Any](),
            kCVPixelBufferMetalCompatibilityKey as String: true
        ])
        videoOut.alwaysCopiesSampleData = false
        reader.add(videoOut)

        var audioOut: AVAssetReaderTrackOutput?
        if let audioTrack {
            let o = AVAssetReaderTrackOutput(track: audioTrack, outputSettings: nil)
            reader.add(o)
            audioOut = o
        }

        // MARK: Writer
        try? FileManager.default.removeItem(at: output)
        let writer = try AVAssetWriter(outputURL: output, fileType: .mov)

        var videoSettings: [String: Any] = [
            AVVideoCodecKey: AVVideoCodecType.hevc,
            AVVideoWidthKey: width,
            AVVideoHeightKey: height,
            AVVideoCompressionPropertiesKey: [
                AVVideoAverageBitRateKey: Int(settings.bitrateMbps * 1_000_000),
                AVVideoExpectedSourceFrameRateKey: Int(outputFPS.rounded()),
                AVVideoMaxKeyFrameIntervalKey: Int(outputFPS.rounded())
            ] as [String: Any]
        ]
        if let color = colorProperties(from: videoFormats.first) {
            videoSettings[AVVideoColorPropertiesKey] = color
        }

        let videoIn = AVAssetWriterInput(mediaType: .video, outputSettings: videoSettings)
        videoIn.expectsMediaDataInRealTime = false
        videoIn.transform = transform
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(
            assetWriterInput: videoIn,
            sourcePixelBufferAttributes: [
                kCVPixelBufferPixelFormatTypeKey as String: pixelFormat,
                kCVPixelBufferWidthKey as String: width,
                kCVPixelBufferHeightKey as String: height
            ]
        )
        writer.add(videoIn)

        var audioIn: AVAssetWriterInput?
        if audioOut != nil {
            let a = AVAssetWriterInput(mediaType: .audio, outputSettings: nil, sourceFormatHint: audioFormat)
            a.expectsMediaDataInRealTime = false
            writer.add(a)
            audioIn = a
        }

        // MARK: Обработчик кадров
        let quality: VTFrameRateConversionConfiguration.QualityPrioritization =
            settings.highQuality ? .quality : .normal
        guard let config = VTFrameRateConversionConfiguration(
            frameWidth: width,
            frameHeight: height,
            usePrecomputedFlow: false,
            qualityPrioritization: quality,
            revision: .revision1
        ) else {
            throw RenderError.configurationFailed
        }

        var poolOut: CVPixelBufferPool?
        CVPixelBufferPoolCreate(
            nil,
            [kCVPixelBufferPoolMinimumBufferCountKey as String: 4] as CFDictionary,
            [
                kCVPixelBufferPixelFormatTypeKey as String: pixelFormat,
                kCVPixelBufferWidthKey as String: width,
                kCVPixelBufferHeightKey as String: height,
                kCVPixelBufferIOSurfacePropertiesKey as String: [String: Any](),
                kCVPixelBufferMetalCompatibilityKey as String: true
            ] as CFDictionary,
            &poolOut
        )
        guard let pool = poolOut else { throw RenderError.frameCreationFailed }

        let processor = VTFrameProcessor()
        try processor.startSession(configuration: config)

        guard writer.startWriting() else {
            throw RenderError.writer(writer.error?.localizedDescription ?? "не удалось начать запись")
        }
        writer.startSession(atSourceTime: .zero)
        guard reader.startReading() else {
            throw RenderError.reader(reader.error?.localizedDescription ?? "не удалось начать чтение")
        }

        // MARK: Запуск
        var sessionOpen = true
        do {
            try await withThrowingTaskGroup(of: Void.self) { group in
                group.addTask {
                    try await processVideo(
                        videoOut: videoOut, videoIn: videoIn, adaptor: adaptor,
                        writer: writer, processor: processor, pool: pool,
                        totalFrames: totalFrames, progress: progress
                    )
                }
                if let audioOut, let audioIn {
                    group.addTask {
                        try await copyAudio(audioOut: audioOut, audioIn: audioIn, writer: writer)
                    }
                }
                try await group.waitForAll()
            }
            processor.endSession()
            sessionOpen = false

            await writer.finishWriting()
            guard writer.status == .completed else {
                throw RenderError.writer(writer.error?.localizedDescription ?? "неизвестная ошибка")
            }
            progress(1.0)
        } catch {
            if sessionOpen { processor.endSession() }
            reader.cancelReading()
            writer.cancelWriting()
            try? FileManager.default.removeItem(at: output)
            throw error
        }
    }

    // MARK: - Видео

    private static func processVideo(
        videoOut: AVAssetReaderTrackOutput,
        videoIn: AVAssetWriterInput,
        adaptor: AVAssetWriterInputPixelBufferAdaptor,
        writer: AVAssetWriter,
        processor: VTFrameProcessor,
        pool: CVPixelBufferPool,
        totalFrames: Double,
        progress: @Sendable (Double) -> Void
    ) async throws {

        var previous: (buffer: CVPixelBuffer, pts: CMTime)?
        var count = 0.0

        func append(_ buffer: CVPixelBuffer, _ pts: CMTime) async throws {
            try await waitUntilReady(videoIn, writer: writer)
            if !adaptor.append(buffer, withPresentationTime: pts) {
                throw RenderError.writer(writer.error?.localizedDescription ?? "не удалось добавить кадр")
            }
        }

        while let sample = videoOut.copyNextSampleBuffer() {
            try Task.checkCancellation()
            guard let buffer = CMSampleBufferGetImageBuffer(sample) else { continue }
            let pts = CMSampleBufferGetPresentationTimeStamp(sample)

            if let prev = previous {
                // 1) исходный кадр
                try await append(prev.buffer, prev.pts)

                // 2) промежуточный кадр на середине интервала
                let delta = CMTimeSubtract(pts, prev.pts)
                if delta.seconds > 0 {
                    let mid = CMTimeAdd(prev.pts, CMTimeMultiplyByFloat64(delta, multiplier: 0.5))

                    var dstBuffer: CVPixelBuffer?
                    CVPixelBufferPoolCreatePixelBuffer(nil, pool, &dstBuffer)
                    guard
                        let dst = dstBuffer,
                        let srcFrame = VTFrameProcessorFrame(buffer: prev.buffer, presentationTimeStamp: prev.pts),
                        let nextFrame = VTFrameProcessorFrame(buffer: buffer, presentationTimeStamp: pts),
                        let dstFrame = VTFrameProcessorFrame(buffer: dst, presentationTimeStamp: mid),
                        let params = VTFrameRateConversionParameters(
                            sourceFrame: srcFrame,
                            nextFrame: nextFrame,
                            opticalFlow: nil,
                            interpolationPhase: [0.5],
                            submissionMode: .sequential,
                            destinationFrames: [dstFrame]
                        )
                    else {
                        throw RenderError.frameCreationFailed
                    }

                    CVBufferPropagateAttachments(prev.buffer, dst)
                    try await processor.process(parameters: params)
                    try await append(dst, mid)
                }
            }

            previous = (buffer, pts)
            count += 1
            if Int(count) % 4 == 0 {
                progress(min(0.99, count / totalFrames))
            }
        }

        // последний кадр
        if let last = previous {
            try await append(last.buffer, last.pts)
        }
        videoIn.markAsFinished()
    }

    // MARK: - Аудио (без перекодирования)

    private static func copyAudio(
        audioOut: AVAssetReaderTrackOutput,
        audioIn: AVAssetWriterInput,
        writer: AVAssetWriter
    ) async throws {
        while let sample = audioOut.copyNextSampleBuffer() {
            try Task.checkCancellation()
            try await waitUntilReady(audioIn, writer: writer)
            if !audioIn.append(sample) {
                throw RenderError.writer(writer.error?.localizedDescription ?? "не удалось добавить звук")
            }
        }
        audioIn.markAsFinished()
    }

    // MARK: - Вспомогательное

    private static func waitUntilReady(_ input: AVAssetWriterInput, writer: AVAssetWriter) async throws {
        while !input.isReadyForMoreMediaData {
            try Task.checkCancellation()
            if writer.status == .failed {
                throw RenderError.writer(writer.error?.localizedDescription ?? "запись прервана")
            }
            try await Task.sleep(nanoseconds: 2_000_000)
        }
    }

    /// Сохраняем цветовую схему исходника (в т.ч. HDR/HLG с iPhone),
    /// но только для заведомо допустимых значений.
    private static func colorProperties(from desc: CMFormatDescription?) -> [String: String]? {
        guard
            let desc,
            let ext = CMFormatDescriptionGetExtensions(desc) as? [String: Any],
            let primaries = ext[kCVImageBufferColorPrimariesKey as String] as? String,
            let transfer = ext[kCVImageBufferTransferFunctionKey as String] as? String,
            let matrix = ext[kCVImageBufferYCbCrMatrixKey as String] as? String
        else { return nil }

        let okPrimaries: Set<String> = ["ITU_R_709_2", "ITU_R_2020", "P3_D65"]
        let okTransfer: Set<String> = ["ITU_R_709_2", "ITU_R_2100_HLG", "SMPTE_ST_2084_PQ"]
        let okMatrix: Set<String> = ["ITU_R_709_2", "ITU_R_2020", "ITU_R_601_4"]
        guard okPrimaries.contains(primaries), okTransfer.contains(transfer), okMatrix.contains(matrix) else {
            return nil
        }
        return [
            AVVideoColorPrimariesKey: primaries,
            AVVideoTransferFunctionKey: transfer,
            AVVideoYCbCrMatrixKey: matrix
        ]
    }
}
