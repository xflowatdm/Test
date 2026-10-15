import AVFoundation
import CoreImage
import CoreVideo
import VideoToolbox

private final class FirstFrameFlag: @unchecked Sendable {
    var written = false
}

/// Применяет цветокоррекцию ко всем кадрам и пересобирает видео (частота кадров и звук сохраняются).
enum ColorExporter {

    static func export(
        source: URL,
        output: URL,
        grade: GradeBox,
        codec: VideoCodec,
        bitrateMbps: Double,
        progress: @escaping ProgressHandler
    ) async throws {
        let flag = FirstFrameFlag()
        do {
            try await run(source: source, output: output, grade: grade, codec: codec,
                          bitrateMbps: bitrateMbps, tenBit: codec.wantsTenBit, flag: flag, progress: progress)
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            // 10 бит не получились ещё до первого кадра — пробуем 8
            if codec.wantsTenBit && !flag.written {
                progress(0, "10 бит недоступны, пишу в 8 бит")
                try await run(source: source, output: output, grade: grade, codec: codec,
                              bitrateMbps: bitrateMbps, tenBit: false, flag: flag, progress: progress)
            } else {
                throw error
            }
        }
    }

    private static func run(
        source: URL,
        output: URL,
        grade: GradeBox,
        codec: VideoCodec,
        bitrateMbps: Double,
        tenBit: Bool,
        flag: FirstFrameFlag,
        progress: @escaping ProgressHandler
    ) async throws {

        Breadcrumb.set("цвет: чтение параметров видео")
        let asset = AVURLAsset(url: source)
        guard let videoTrack = try await asset.loadTracks(withMediaType: .video).first else {
            throw RenderError.noVideoTrack
        }
        let naturalSize = try await videoTrack.load(.naturalSize)
        let transform = try await videoTrack.load(.preferredTransform)
        let nominalFPS = try await videoTrack.load(.nominalFrameRate)
        let duration = try await asset.load(.duration)
        let videoFormats = try await videoTrack.load(.formatDescriptions)
        let audioTrack = try await asset.loadTracks(withMediaType: .audio).first
        let audioFormat = try await audioTrack?.load(.formatDescriptions).first

        let width = Int(naturalSize.width.rounded())
        let height = Int(naturalSize.height.rounded())
        let fps = nominalFPS > 0 ? Int(nominalFPS.rounded()) : 30
        let totalFrames = max(1, duration.seconds * Double(fps))
        let pixelFormat: OSType = tenBit ? FrameInterpolator.format10 : FrameInterpolator.format8

        // Reader
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

        // Writer
        try? FileManager.default.removeItem(at: output)
        let writer = try AVAssetWriter(outputURL: output, fileType: .mov)
        let colorProps = FrameInterpolator.colorProperties(from: videoFormats.first)

        func makeSettings(color: [String: String]?) -> [String: Any] {
            var s: [String: Any] = [AVVideoWidthKey: width, AVVideoHeightKey: height]
            switch codec {
            case .hevc10, .hevc8:
                let profile: String = tenBit
                    ? (kVTProfileLevel_HEVC_Main10_AutoLevel as String)
                    : (kVTProfileLevel_HEVC_Main_AutoLevel as String)
                s[AVVideoCodecKey] = AVVideoCodecType.hevc
                s[AVVideoCompressionPropertiesKey] = [
                    AVVideoAverageBitRateKey: Int(bitrateMbps * 1_000_000),
                    AVVideoExpectedSourceFrameRateKey: fps,
                    AVVideoMaxKeyFrameIntervalKey: fps,
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

        var videoSettings = makeSettings(color: colorProps)
        if !writer.canApply(outputSettings: videoSettings, forMediaType: .video) {
            videoSettings = makeSettings(color: nil)
            guard writer.canApply(outputSettings: videoSettings, forMediaType: .video) else {
                throw RenderError.codecUnsupported(codec.title)
            }
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

        // Пул выходных буферов
        var poolOut: CVPixelBufferPool?
        CVPixelBufferPoolCreate(
            nil, nil,
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

        guard writer.startWriting() else {
            throw RenderError.writer(writer.error?.localizedDescription ?? "не удалось начать запись")
        }
        writer.startSession(atSourceTime: .zero)
        guard reader.startReading() else {
            throw RenderError.reader(reader.error?.localizedDescription ?? "не удалось начать чтение")
        }

        do {
            try await withThrowingTaskGroup(of: Void.self) { group in
                group.addTask {
                    try await gradeFrames(
                        videoOut: videoOut, videoIn: videoIn, adaptor: adaptor, writer: writer,
                        pool: pool, grade: grade, flag: flag, totalFrames: totalFrames, progress: progress
                    )
                }
                if let audioOut, let audioIn {
                    group.addTask {
                        try await FrameInterpolator.copyAudio(audioOut: audioOut, audioIn: audioIn, writer: writer)
                    }
                }
                try await group.waitForAll()
            }

            progress(0.99, "Финализация файла…")
            await writer.finishWriting()
            guard writer.status == .completed else {
                throw RenderError.writer(writer.error?.localizedDescription ?? "неизвестная ошибка")
            }
            Breadcrumb.set("цвет: файл записан")
            progress(1.0, "Файл готов")
        } catch {
            reader.cancelReading()
            writer.cancelWriting()
            try? FileManager.default.removeItem(at: output)
            throw error
        }
    }

    private static func gradeFrames(
        videoOut: AVAssetReaderTrackOutput,
        videoIn: AVAssetWriterInput,
        adaptor: AVAssetWriterInputPixelBufferAdaptor,
        writer: AVAssetWriter,
        pool: CVPixelBufferPool,
        grade: GradeBox,
        flag: FirstFrameFlag,
        totalFrames: Double,
        progress: ProgressHandler
    ) async throws {

        func nextSample() -> CMSampleBuffer? {
            autoreleasepool { videoOut.copyNextSampleBuffer() }
        }

        let context = ColorGrader.context
        var count = 0.0

        while let sample = nextSample() {
            try Task.checkCancellation()
            guard let src = CMSampleBufferGetImageBuffer(sample) else { continue }
            let pts = CMSampleBufferGetPresentationTimeStamp(sample)

            var dstOut: CVPixelBuffer?
            CVPixelBufferPoolCreatePixelBuffer(nil, pool, &dstOut)
            guard let dst = dstOut else { throw RenderError.frameCreationFailed }

            let (params, match) = grade.get()
            let graded = ColorGrader.apply(to: CIImage(cvPixelBuffer: src), params: params, match: match)
            context.render(graded, to: dst)
            CVBufferPropagateAttachments(src, dst)

            try await FrameInterpolator.waitUntilReady(videoIn, writer: writer)
            if !adaptor.append(dst, withPresentationTime: pts) {
                throw RenderError.writer(writer.error?.localizedDescription ?? "не удалось добавить кадр")
            }
            flag.written = true

            count += 1
            if Int(count) % 10 == 0 {
                Breadcrumb.set("цвет: кадр \(Int(count)) из ~\(Int(totalFrames))")
                progress(min(0.98, count / totalFrames), "Цветокоррекция кадров")
            }
        }
        videoIn.markAsFinished()
    }
}
