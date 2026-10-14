import AVFoundation
import VideoToolbox
import CoreVideo
import Accelerate
import os

typealias ProgressHandler = @Sendable (Double, String) -> Void

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
            return "Разрешение \(w)×\(h) не поддерживается. Максимум 4096×2160 (для вертикальных видео 2160×4096)."
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

/// Запоминает последний этап рендера. Если приложение вылетит,
/// при следующем запуске мы увидим, на чём это случилось.
enum Breadcrumb {
    private static let key = "lastRenderStage"
    static func set(_ text: String) { UserDefaults.standard.set(text, forKey: key) }
    static func clear() { UserDefaults.standard.removeObject(forKey: key) }
    static var last: String? { UserDefaults.standard.string(forKey: key) }
    static func freeMemoryMB() -> Int { Int(os_proc_available_memory()) / 1_048_576 }
}

enum FrameInterpolator {

    private static let pixelFormat = kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange

    static func render(
        source: URL,
        output: URL,
        settings: RenderSettings,
        progress: @escaping ProgressHandler
    ) async throws {

        guard VTFrameRateConversionConfiguration.isSupported else {
            throw RenderError.unsupportedDevice
        }

        // MARK: Исходник
        Breadcrumb.set("чтение параметров видео")
        let asset = AVURLAsset(url: source)
        guard let videoTrack = try await asset.loadTracks(withMediaType: .video).first else {
            throw RenderError.noVideoTrack
        }
        let naturalSize = try await videoTrack.load(.naturalSize)
        let transform = try await videoTrack.load(.preferredTransform)
        let nominalFPS = try await videoTrack.load(.nominalFrameRate)
        let duration = try await asset.load(.duration)
        let videoFormats = try await videoTrack.load(.formatDescriptions)

        let naturalW = Int(naturalSize.width.rounded())
        let naturalH = Int(naturalSize.height.rounded())

        // Интерполятор принимает кадры не больше 4096×2160.
        // Вертикальные кадры на время обработки поворачиваем на 90°,
        // а в итоговом файле возвращаем нужную ориентацию через метаданные.
        let fitsDirect = naturalW <= 4096 && naturalH <= 2160
        let fitsRotated = naturalH <= 4096 && naturalW <= 2160
        guard fitsDirect || fitsRotated else {
            throw RenderError.unsupportedSize(naturalW, naturalH)
        }
        let rotate = !fitsDirect
        let width = rotate ? naturalH : naturalW
        let height = rotate ? naturalW : naturalH

        var writerTransform = transform
        if rotate {
            let undo = CGAffineTransform(a: 0, b: -1, c: 1, d: 0, tx: 0, ty: CGFloat(width))
            writerTransform = undo.concatenating(transform)
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
        videoIn.transform = writerTransform
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

        Breadcrumb.set("запуск обработчика")
        let processor = VTFrameProcessor()
        try processor.startSession(configuration: config)

        guard writer.startWriting() else {
            processor.endSession()
            throw RenderError.writer(writer.error?.localizedDescription ?? "не удалось начать запись")
        }
        writer.startSession(atSourceTime: .zero)
        guard reader.startReading() else {
            processor.endSession()
            throw RenderError.reader(reader.error?.localizedDescription ?? "не удалось начать чтение")
        }

        // MARK: Запуск
        var sessionOpen = true
        do {
            try await withThrowingTaskGroup(of: Void.self) { group in
                group.addTask {
                    try await processVideo(
                        videoOut: videoOut, videoIn: videoIn, adaptor: adaptor,
                        writer: writer, processor: processor, pool: pool, rotate: rotate,
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

            Breadcrumb.set("закрытие сессии обработчика, своб. память \(Breadcrumb.freeMemoryMB()) МБ")
            processor.endSession()
            sessionOpen = false

            Breadcrumb.set("финализация файла (finishWriting), своб. память \(Breadcrumb.freeMemoryMB()) МБ")
            progress(0.99, "Финализация файла…")
            await writer.finishWriting()
            guard writer.status == .completed else {
                throw RenderError.writer(writer.error?.localizedDescription ?? "неизвестная ошибка")
            }
            Breadcrumb.set("файл записан")
            progress(1.0, "Файл готов")
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
        rotate: Bool,
        totalFrames: Double,
        progress: ProgressHandler
    ) async throws {

        var previous: (buffer: CVPixelBuffer, pts: CMTime)?
        var count = 0.0

        func nextSample() -> CMSampleBuffer? {
            autoreleasepool { videoOut.copyNextSampleBuffer() }
        }

        func append(_ buffer: CVPixelBuffer, _ pts: CMTime) async throws {
            try await waitUntilReady(videoIn, writer: writer)
            if !adaptor.append(buffer, withPresentationTime: pts) {
                throw RenderError.writer(writer.error?.localizedDescription ?? "не удалось добавить кадр")
            }
        }

        func prepare(_ src: CVPixelBuffer) throws -> CVPixelBuffer {
            guard rotate else { return src }
            var out: CVPixelBuffer?
            CVPixelBufferPoolCreatePixelBuffer(nil, pool, &out)
            guard let dst = out else { throw RenderError.frameCreationFailed }
            try rotateClockwise90(src, into: dst)
            CVBufferPropagateAttachments(src, dst)
            return dst
        }

        while let sample = nextSample() {
            try Task.checkCancellation()
            guard let rawBuffer = CMSampleBufferGetImageBuffer(sample) else { continue }
            let pts = CMSampleBufferGetPresentationTimeStamp(sample)
            let buffer = try prepare(rawBuffer)

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
            if Int(count) % 10 == 0 {
                Breadcrumb.set("кадр \(Int(count)) из ~\(Int(totalFrames)), своб. память \(Breadcrumb.freeMemoryMB()) МБ")
                progress(min(0.98, count / totalFrames), "Обработка кадров")
            }
        }

        // последний кадр
        Breadcrumb.set("запись последнего кадра, своб. память \(Breadcrumb.freeMemoryMB()) МБ")
        if let last = previous {
            try await append(last.buffer, last.pts)
        }
        videoIn.markAsFinished()
        Breadcrumb.set("видеодорожка завершена")
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

    // MARK: - Поворот кадра на 90° по часовой (YCbCr 4:2:0, без потерь)

    private static func rotateClockwise90(_ src: CVPixelBuffer, into dst: CVPixelBuffer) throws {
        CVPixelBufferLockBaseAddress(src, .readOnly)
        CVPixelBufferLockBaseAddress(dst, [])
        defer {
            CVPixelBufferUnlockBaseAddress(dst, [])
            CVPixelBufferUnlockBaseAddress(src, .readOnly)
        }

        for plane in 0..<2 {
            guard
                let sBase = CVPixelBufferGetBaseAddressOfPlane(src, plane),
                let dBase = CVPixelBufferGetBaseAddressOfPlane(dst, plane)
            else { throw RenderError.frameCreationFailed }

            var s = vImage_Buffer(
                data: sBase,
                height: vImagePixelCount(CVPixelBufferGetHeightOfPlane(src, plane)),
                width: vImagePixelCount(CVPixelBufferGetWidthOfPlane(src, plane)),
                rowBytes: CVPixelBufferGetBytesPerRowOfPlane(src, plane)
            )
            var d = vImage_Buffer(
                data: dBase,
                height: vImagePixelCount(CVPixelBufferGetHeightOfPlane(dst, plane)),
                width: vImagePixelCount(CVPixelBufferGetWidthOfPlane(dst, plane)),
                rowBytes: CVPixelBufferGetBytesPerRowOfPlane(dst, plane)
            )
            let direction = UInt8(kRotate90DegreesClockwise)
            let flags = vImage_Flags(kvImageNoFlags)

            // plane 0 — яркость (8 бит), plane 1 — пары Cb/Cr (16 бит на пиксель)
            let error = plane == 0
                ? vImageRotate90_Planar8(&s, &d, direction, 0, flags)
                : vImageRotate90_Planar16U(&s, &d, direction, 0, flags)
            guard error == kvImageNoError else { throw RenderError.frameCreationFailed }
        }
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
