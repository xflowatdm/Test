import AVFoundation
import VideoToolbox
import CoreVideo
import Accelerate
import os

typealias ProgressHandler = @Sendable (Double, String) -> Void

// MARK: - Кодеки

enum VideoCodec: String, CaseIterable, Identifiable {
    case hevc10
    case hevc8
    case proRes422
    case proRes422HQ

    var id: String { rawValue }

    var title: String {
        switch self {
        case .hevc10: return "HEVC 10 бит"
        case .hevc8: return "HEVC 8 бит"
        case .proRes422: return "ProRes 422"
        case .proRes422HQ: return "ProRes 422 HQ"
        }
    }

    var details: String {
        switch self {
        case .hevc10:
            return "Рекомендуется. Лучшее качество при разумном размере файла, меньше полос в градиентах, сохраняет HDR."
        case .hevc8:
            return "Меньше нагрузка и совместимость, но возможны полосы в градиентах."
        case .proRes422:
            return "Студийный кодек почти без потерь. Файлы в 5–10 раз больше. Нужен iPhone 15 Pro или новее."
        case .proRes422HQ:
            return "Максимальное качество, визуально без потерь. Очень большие файлы. Нужен iPhone 15 Pro или новее."
        }
    }

    var usesBitrate: Bool { self == .hevc10 || self == .hevc8 }
    var wantsTenBit: Bool { self != .hevc8 }
}

// MARK: - Настройки и ошибки

struct RenderSettings {
    /// Битрейт результата в Мбит/с (для HEVC)
    var bitrateMbps: Double
    /// Режим повышенного качества интерполяции («сглаживание»)
    var highQuality: Bool
    /// Сила размытия движения 1...100 (0 — выключено)
    var motionBlur: Int
    /// Резкость достроенных кадров 0...100 (0 — выключено)
    var sharpness: Int
    /// Кодек результата
    var codec: VideoCodec
}

enum RenderError: LocalizedError {
    case unsupportedDevice
    case noVideoTrack
    case unsupportedSize(Int, Int)
    case configurationFailed
    case frameCreationFailed
    case codecUnsupported(String)
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
        case .codecUnsupported(let name):
            return "Этот iPhone не может записать видео в формате «\(name)». Выбери HEVC."
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

// MARK: - Конвейер

enum FrameInterpolator {

    private static let format8 = OSType(kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange)
    private static let format10 = OSType(kCVPixelFormatType_420YpCbCr10BiPlanarVideoRange)

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
        let outputFPS = Int((sourceFPS * 2).rounded())
        let totalFrames = max(1, duration.seconds * sourceFPS)

        // MARK: Настройки обработчиков
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

        var blurConfig: VTMotionBlurConfiguration?
        if settings.motionBlur > 0 {
            guard
                VTMotionBlurConfiguration.isSupported,
                let c = VTMotionBlurConfiguration(
                    frameWidth: width,
                    frameHeight: height,
                    usePrecomputedFlow: false,
                    qualityPrioritization: .normal,
                    revision: .revision1
                )
            else {
                throw RenderError.configurationFailed
            }
            blurConfig = c
        }

        // 10 бит используем, только если его поддерживают все обработчики
        let frcSupportsTen = config.frameSupportedPixelFormats.contains { ($0 as NSNumber).uint32Value == format10 }
        let blurSupportsTen = blurConfig?.frameSupportedPixelFormats.contains { ($0 as NSNumber).uint32Value == format10 } ?? true
        let useTenBit = settings.codec.wantsTenBit && frcSupportsTen && blurSupportsTen
        let pixelFormat: OSType = useTenBit ? format10 : format8

        let depthNote = settings.codec.wantsTenBit && !useTenBit ? " (10 бит недоступны, пишу в 8 бит)" : ""
        progress(0, "Формат: \(settings.codec.title)\(depthNote)")

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

        let colorProps = colorProperties(from: videoFormats.first)

        func makeVideoSettings(color: [String: String]?) -> [String: Any] {
            var s: [String: Any] = [
                AVVideoWidthKey: width,
                AVVideoHeightKey: height
            ]
            switch settings.codec {
            case .hevc10, .hevc8:
                let profile: String = useTenBit
                    ? (kVTProfileLevel_HEVC_Main10_AutoLevel as String)
                    : (kVTProfileLevel_HEVC_Main_AutoLevel as String)
                s[AVVideoCodecKey] = AVVideoCodecType.hevc
                s[AVVideoCompressionPropertiesKey] = [
                    AVVideoAverageBitRateKey: Int(settings.bitrateMbps * 1_000_000),
                    AVVideoExpectedSourceFrameRateKey: outputFPS,
                    AVVideoMaxKeyFrameIntervalKey: outputFPS,
                    AVVideoProfileLevelKey: profile
                ] as [String: Any]
            case .proRes422:
                s[AVVideoCodecKey] = AVVideoCodecType(rawValue: "apcn")
            case .proRes422HQ:
                s[AVVideoCodecKey] = AVVideoCodecType(rawValue: "apch")
            }
            if let color { s[AVVideoColorPropertiesKey] = color }
            return s
        }

        var videoSettings = makeVideoSettings(color: colorProps)
        if !writer.canApply(outputSettings: videoSettings, forMediaType: .video) {
            // возможно, не подошли цветовые метки — пробуем без них
            videoSettings = makeVideoSettings(color: nil)
            guard writer.canApply(outputSettings: videoSettings, forMediaType: .video) else {
                throw RenderError.codecUnsupported(settings.codec.title)
            }
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

        // MARK: Пул буферов (с учётом требований обработчика)
        func makePool(extra: [String: Any]?) -> CVPixelBufferPool? {
            var attrs: [String: Any] = extra ?? [:]
            attrs[kCVPixelBufferPixelFormatTypeKey as String] = pixelFormat
            attrs[kCVPixelBufferWidthKey as String] = width
            attrs[kCVPixelBufferHeightKey as String] = height
            attrs[kCVPixelBufferIOSurfacePropertiesKey as String] = [String: Any]()
            attrs[kCVPixelBufferMetalCompatibilityKey as String] = true
            var out: CVPixelBufferPool?
            CVPixelBufferPoolCreate(
                nil,
                [kCVPixelBufferPoolMinimumBufferCountKey as String: 4] as CFDictionary,
                attrs as CFDictionary,
                &out
            )
            return out
        }
        guard let pool = makePool(extra: config.destinationPixelBufferAttributes) ?? makePool(extra: nil) else {
            throw RenderError.frameCreationFailed
        }

        Breadcrumb.set("запуск обработчика")
        let processor = VTFrameProcessor()
        try processor.startSession(configuration: config)

        var blurProcessorVar: VTFrameProcessor?
        if let blurConfig {
            let bp = VTFrameProcessor()
            do {
                try bp.startSession(configuration: blurConfig)
            } catch {
                processor.endSession()
                throw error
            }
            blurProcessorVar = bp
        }
        let blurProcessor = blurProcessorVar
        let endSessions = {
            processor.endSession()
            blurProcessor?.endSession()
        }

        guard writer.startWriting() else {
            endSessions()
            throw RenderError.writer(writer.error?.localizedDescription ?? "не удалось начать запись")
        }
        writer.startSession(atSourceTime: .zero)
        guard reader.startReading() else {
            endSessions()
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
                        blurProcessor: blurProcessor, blurStrength: settings.motionBlur, sharpness: settings.sharpness,
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
            endSessions()
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
            if sessionOpen { endSessions() }
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
        blurProcessor: VTFrameProcessor?,
        blurStrength: Int,
        sharpness: Int,
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

        let sharpener = sharpness > 0 ? LumaSharpener(strength: sharpness) : nil

        let blurStage = blurProcessor.map {
            MotionBlurStage(processor: $0, pool: pool, strength: blurStrength)
        }

        // Выходной кадр: через размытие движения (если включено) и в запись
        func emit(_ buffer: CVPixelBuffer, _ pts: CMTime) async throws {
            if let stage = blurStage {
                if let out = try await stage.push(buffer, pts) {
                    try await append(out.buffer, out.pts)
                }
            } else {
                try await append(buffer, pts)
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
                try await emit(prev.buffer, prev.pts)

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
                    // Достроенные кадры чуть мягче оригинальных — подтягиваем резкость
                    if let sharpener { try sharpener.apply(to: dst) }
                    try await emit(dst, mid)
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
            try await emit(last.buffer, last.pts)
        }
        if let stage = blurStage, let out = try await stage.flush() {
            try await append(out.buffer, out.pts)
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

    // MARK: - Поворот кадра на 90° по часовой (YCbCr 4:2:0, 8 и 10 бит, без потерь)

    private static func rotateClockwise90(_ src: CVPixelBuffer, into dst: CVPixelBuffer) throws {
        CVPixelBufferLockBaseAddress(src, .readOnly)
        CVPixelBufferLockBaseAddress(dst, [])
        defer {
            CVPixelBufferUnlockBaseAddress(dst, [])
            CVPixelBufferUnlockBaseAddress(src, .readOnly)
        }

        let tenBit = CVPixelBufferGetPixelFormatType(src) == format10
        let direction = UInt8(kRotate90DegreesClockwise)
        let flags = vImage_Flags(kvImageNoFlags)
        let background4 = [UInt8](repeating: 0, count: 4)

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

            // Байт на «пиксель» плоскости: яркость 1 или 2, пары Cb/Cr — 2 или 4
            let bytesPerPixel = (plane == 0 ? 1 : 2) * (tenBit ? 2 : 1)
            let error: vImage_Error
            switch bytesPerPixel {
            case 1:
                error = vImageRotate90_Planar8(&s, &d, direction, 0, flags)
            case 2:
                error = vImageRotate90_Planar16U(&s, &d, direction, 0, flags)
            default:
                error = vImageRotate90_ARGB8888(&s, &d, direction, background4, flags)
            }
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

    /// Цветовая схема исходника (в т.ч. HDR/HLG и Display P3).
    /// Если AVAssetWriter не примет значения, в вызывающем коде пробуем без них.
    private static func colorProperties(from desc: CMFormatDescription?) -> [String: String]? {
        guard
            let desc,
            let ext = CMFormatDescriptionGetExtensions(desc) as? [String: Any],
            let primaries = ext[kCVImageBufferColorPrimariesKey as String] as? String,
            let transfer = ext[kCVImageBufferTransferFunctionKey as String] as? String,
            let matrix = ext[kCVImageBufferYCbCrMatrixKey as String] as? String
        else { return nil }

        return [
            AVVideoColorPrimariesKey: primaries,
            AVVideoTransferFunctionKey: transfer,
            AVVideoYCbCrMatrixKey: matrix
        ]
    }
}

// MARK: - Размытие движения

/// Размытие движения для итоговой последовательности кадров (оригинальные + достроенные).
/// Каждому кадру нужны соседи (предыдущий и следующий), поэтому работаем с задержкой в один кадр.
final class MotionBlurStage {
    typealias Frame = (buffer: CVPixelBuffer, pts: CMTime)

    private let processor: VTFrameProcessor
    private let pool: CVPixelBufferPool
    private let strength: Int
    private var previous: Frame?
    private var current: Frame?

    init(processor: VTFrameProcessor, pool: CVPixelBufferPool, strength: Int) {
        self.processor = processor
        self.pool = pool
        self.strength = min(100, max(1, strength))
    }

    /// Принимает следующий кадр; возвращает готовый (размытый) предыдущий, если он есть.
    func push(_ buffer: CVPixelBuffer, _ pts: CMTime) async throws -> Frame? {
        guard let cur = current else {
            current = (buffer, pts)
            return nil
        }
        let out = try await blur(cur, previous: previous, next: (buffer, pts))
        previous = cur
        current = (buffer, pts)
        return out
    }

    /// Обрабатывает самый последний кадр (следующего нет).
    func flush() async throws -> Frame? {
        guard let cur = current else { return nil }
        let out = try await blur(cur, previous: previous, next: nil)
        current = nil
        previous = nil
        return out
    }

    private func blur(_ source: Frame, previous: Frame?, next: Frame?) async throws -> Frame {
        var dstBuffer: CVPixelBuffer?
        CVPixelBufferPoolCreatePixelBuffer(nil, pool, &dstBuffer)
        guard
            let dst = dstBuffer,
            let srcFrame = VTFrameProcessorFrame(buffer: source.buffer, presentationTimeStamp: source.pts),
            let dstFrame = VTFrameProcessorFrame(buffer: dst, presentationTimeStamp: source.pts)
        else {
            throw RenderError.frameCreationFailed
        }
        let prevFrame = previous.flatMap {
            VTFrameProcessorFrame(buffer: $0.buffer, presentationTimeStamp: $0.pts)
        }
        let nextFrame = next.flatMap {
            VTFrameProcessorFrame(buffer: $0.buffer, presentationTimeStamp: $0.pts)
        }
        guard let params = VTMotionBlurParameters(
            sourceFrame: srcFrame,
            nextFrame: nextFrame,
            previousFrame: prevFrame,
            nextOpticalFlow: nil,
            previousOpticalFlow: nil,
            motionBlurStrength: strength,
            submissionMode: .sequential,
            destinationFrame: dstFrame
        ) else {
            throw RenderError.frameCreationFailed
        }
        CVBufferPropagateAttachments(source.buffer, dst)
        try await processor.process(parameters: params)
        return (dst, source.pts)
    }
}

// MARK: - Резкость

/// Лёгкая резкость по яркости (Y) для достроенных кадров. Цвет не трогаем, оригинальные кадры не трогаем.
final class LumaSharpener {
    private let amount: Int16
    private var scratch: UnsafeMutableRawPointer?
    private var scratchSize = 0

    init(strength: Int) {
        // 0...100 на ползунке → сила ядра 1...50
        amount = Int16(min(50, max(1, strength / 2)))
    }

    deinit { scratch?.deallocate() }

    func apply(to buffer: CVPixelBuffer) throws {
        CVPixelBufferLockBaseAddress(buffer, [])
        defer { CVPixelBufferUnlockBaseAddress(buffer, []) }

        guard let base = CVPixelBufferGetBaseAddressOfPlane(buffer, 0) else {
            throw RenderError.frameCreationFailed
        }
        let w = CVPixelBufferGetWidthOfPlane(buffer, 0)
        let h = CVPixelBufferGetHeightOfPlane(buffer, 0)
        let rowBytes = CVPixelBufferGetBytesPerRowOfPlane(buffer, 0)

        let is16 = CVPixelBufferGetPixelFormatType(buffer) == OSType(kCVPixelFormatType_420YpCbCr10BiPlanarVideoRange)
        let rowLen = w * (is16 ? 2 : 1)

        let needed = rowLen * h
        if scratchSize < needed {
            scratch?.deallocate()
            scratch = UnsafeMutableRawPointer.allocate(byteCount: needed, alignment: 64)
            scratchSize = needed
        }
        guard let scratch else { throw RenderError.frameCreationFailed }

        var src = vImage_Buffer(data: base, height: vImagePixelCount(h), width: vImagePixelCount(w), rowBytes: rowBytes)
        var dst = vImage_Buffer(data: scratch, height: vImagePixelCount(h), width: vImagePixelCount(w), rowBytes: rowLen)

        // Ядро 3×3: исходный пиксель + amount × (лапласиан). Сумма = 100, делитель = 100.
        let a = amount
        let kernel: [Int16] = [0, -a, 0, -a, 100 + 4 * a, -a, 0, -a, 0]
        let flags = vImage_Flags(kvImageEdgeExtend)
        let error: vImage_Error = kernel.withUnsafeBufferPointer { k in
            if is16 {
                return vImageConvolve_Planar16U(&src, &dst, nil, 0, 0, k.baseAddress!, 3, 3, 100, 0, flags)
            } else {
                return vImageConvolve_Planar8(&src, &dst, nil, 0, 0, k.baseAddress!, 3, 3, 100, 0, flags)
            }
        }
        guard error == kvImageNoError else { throw RenderError.frameCreationFailed }

        for row in 0..<h {
            memcpy(base + row * rowBytes, scratch + row * rowLen, rowLen)
        }
    }
}
