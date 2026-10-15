import CoreML
import CoreVideo
import CoreImage
import Accelerate

// MARK: - Модели

enum NeuralModel: String, CaseIterable, Identifiable {
    case general = "NeuralGeneral"
    case light = "NeuralLight"

    var id: String { rawValue }

    var title: String {
        switch self {
        case .general: return "Универсальная"
        case .light: return "Лёгкая"
        }
    }

    var details: String {
        switch self {
        case .general:
            return "Real-ESRGAN General v3. Лучше для обычной картинки и игр, но примерно вдвое медленнее."
        case .light:
            return "Real-ESRGAN AnimeVideo v3. Вдвое быстрее, но картинка может стать более «рисованной»."
        }
    }

    /// Скомпилированная модель внутри приложения (появляется, только если конвертация на GitHub прошла)
    var url: URL? {
        Bundle.main.url(forResource: rawValue, withExtension: "mlmodelc", subdirectory: "Models")
            ?? Bundle.main.url(forResource: rawValue, withExtension: "mlmodelc")
    }

    static var available: [NeuralModel] { allCases.filter { $0.url != nil } }
}

// MARK: - Улучшение кадра

/// Прогоняет кадр через нейросеть плитками 256×256 (с перекрытием), уменьшает результат обратно
/// до исходного размера (получается «суперсэмплинг»: чище и чётче) и смешивает с оригиналом по силе.
final class NeuralEnhancer {
    private static let tile = 256
    private static let scale = 4
    private static let overlap = 12

    private let model: MLModel
    private let inputName: String
    private let outputName: String
    /// 0...256
    private let strength: Int
    private let tileInput: CVPixelBuffer
    private let scratch: UnsafeMutableRawPointer

    private var frameBGRA: CVPixelBuffer?
    private var resultBGRA: CVPixelBuffer?
    private var outputPool: CVPixelBufferPool?
    private var bufferKey = ""
    private var outputChecked = false

    init(modelType: NeuralModel, strength: Double) throws {
        guard let url = modelType.url else {
            throw RenderError.neural("модель «\(modelType.title)» не найдена в приложении")
        }
        let config = MLModelConfiguration()
        config.computeUnits = .all
        let m = try MLModel(contentsOf: url, configuration: config)

        guard
            let inName = m.modelDescription.inputDescriptionsByName.keys.first,
            let outName = m.modelDescription.outputDescriptionsByName.keys.first
        else {
            throw RenderError.neural("у модели нет входа или выхода")
        }

        var tb: CVPixelBuffer?
        CVPixelBufferCreate(
            nil, Self.tile, Self.tile, OSType(kCVPixelFormatType_32BGRA),
            [
                kCVPixelBufferIOSurfacePropertiesKey as String: [String: Any](),
                kCVPixelBufferMetalCompatibilityKey as String: true
            ] as CFDictionary,
            &tb
        )
        guard let tileBuffer = tb else { throw RenderError.frameCreationFailed }

        self.model = m
        self.inputName = inName
        self.outputName = outName
        self.tileInput = tileBuffer
        self.scratch = UnsafeMutableRawPointer.allocate(byteCount: Self.tile * Self.tile * 4, alignment: 64)
        self.strength = max(0, min(256, Int(strength / 100 * 256)))
    }

    deinit { scratch.deallocate() }

    /// Принимает кадр YCbCr, возвращает улучшенный кадр того же формата и размера
    func enhance(_ src: CVPixelBuffer) async throws -> CVPixelBuffer {
        let w = CVPixelBufferGetWidth(src)
        let h = CVPixelBufferGetHeight(src)
        let format = CVPixelBufferGetPixelFormatType(src)
        try prepareBuffers(width: w, height: h, format: format)
        guard let frame = frameBGRA, let result = resultBGRA, let pool = outputPool else {
            throw RenderError.frameCreationFailed
        }

        let context = ColorGrader.context
        context.render(CIImage(cvPixelBuffer: src), to: frame)

        let innerStride = Self.tile - 2 * Self.overlap
        var iy = 0
        while iy < h {
            var ix = 0
            while ix < w {
                try Task.checkCancellation()
                try await processTile(frame: frame, result: result, ix: ix, iy: iy, width: w, height: h)
                ix += innerStride
            }
            iy += innerStride
        }

        var dstOut: CVPixelBuffer?
        CVPixelBufferPoolCreatePixelBuffer(nil, pool, &dstOut)
        guard let dst = dstOut else { throw RenderError.frameCreationFailed }
        CVBufferPropagateAttachments(src, dst)
        context.render(CIImage(cvPixelBuffer: result), to: dst)
        return dst
    }

    // MARK: Плитки

    private func processTile(
        frame: CVPixelBuffer, result: CVPixelBuffer,
        ix: Int, iy: Int, width: Int, height: Int
    ) async throws {
        let tile = Self.tile
        let ov = Self.overlap

        // 1) Заполняем вход плиткой с перекрытием (края кадра дублируем)
        CVPixelBufferLockBaseAddress(frame, .readOnly)
        CVPixelBufferLockBaseAddress(tileInput, [])
        if let srcBase = CVPixelBufferGetBaseAddress(frame),
           let dstBase = CVPixelBufferGetBaseAddress(tileInput) {
            let srcStride = CVPixelBufferGetBytesPerRow(frame)
            let dstStride = CVPixelBufferGetBytesPerRow(tileInput)
            let sx0 = ix - ov
            let sy0 = iy - ov
            for ty in 0..<tile {
                let sy = min(max(sy0 + ty, 0), height - 1)
                let srcRow = (srcBase + sy * srcStride).assumingMemoryBound(to: UInt32.self)
                let dstRow = (dstBase + ty * dstStride).assumingMemoryBound(to: UInt32.self)
                for tx in 0..<tile {
                    let sx = min(max(sx0 + tx, 0), width - 1)
                    dstRow[tx] = srcRow[sx]
                }
            }
        }
        CVPixelBufferUnlockBaseAddress(tileInput, [])
        CVPixelBufferUnlockBaseAddress(frame, .readOnly)

        // 2) Нейросеть
        let provider = try MLDictionaryFeatureProvider(
            dictionary: [inputName: MLFeatureValue(pixelBuffer: tileInput)]
        )
        let output = try await model.prediction(from: provider)
        guard let outBuffer = output.featureValue(for: outputName)?.imageBufferValue else {
            throw RenderError.neural("модель не вернула картинку")
        }
        if !outputChecked {
            guard
                CVPixelBufferGetPixelFormatType(outBuffer) == OSType(kCVPixelFormatType_32BGRA),
                CVPixelBufferGetWidth(outBuffer) == tile * Self.scale
            else {
                throw RenderError.neural("неожиданный формат выхода модели")
            }
            outputChecked = true
        }

        // 3) Уменьшаем в 4 раза (1024 → 256)
        CVPixelBufferLockBaseAddress(outBuffer, .readOnly)
        guard let outBase = CVPixelBufferGetBaseAddress(outBuffer) else {
            CVPixelBufferUnlockBaseAddress(outBuffer, .readOnly)
            throw RenderError.neural("нет данных выхода")
        }
        var s = vImage_Buffer(
            data: outBase,
            height: vImagePixelCount(CVPixelBufferGetHeight(outBuffer)),
            width: vImagePixelCount(CVPixelBufferGetWidth(outBuffer)),
            rowBytes: CVPixelBufferGetBytesPerRow(outBuffer)
        )
        var d = vImage_Buffer(
            data: scratch, height: vImagePixelCount(tile), width: vImagePixelCount(tile), rowBytes: tile * 4
        )
        let scaleError = vImageScale_ARGB8888(&s, &d, nil, vImage_Flags(kvImageHighQualityResampling))
        CVPixelBufferUnlockBaseAddress(outBuffer, .readOnly)
        guard scaleError == kvImageNoError else { throw RenderError.neural("не удалось уменьшить результат") }

        // 4) Записываем внутреннюю часть плитки в результат (со смешиванием с оригиналом)
        let innerW = min(tile - 2 * ov, width - ix)
        let innerH = min(tile - 2 * ov, height - iy)

        CVPixelBufferLockBaseAddress(result, [])
        CVPixelBufferLockBaseAddress(frame, .readOnly)
        defer {
            CVPixelBufferUnlockBaseAddress(frame, .readOnly)
            CVPixelBufferUnlockBaseAddress(result, [])
        }
        guard
            let rBase = CVPixelBufferGetBaseAddress(result),
            let fBase = CVPixelBufferGetBaseAddress(frame)
        else { throw RenderError.frameCreationFailed }
        let rStride = CVPixelBufferGetBytesPerRow(result)
        let fStride = CVPixelBufferGetBytesPerRow(frame)

        for row in 0..<innerH {
            let enhanced = (scratch + ((ov + row) * tile + ov) * 4).assumingMemoryBound(to: UInt8.self)
            let dst = (rBase + (iy + row) * rStride + ix * 4).assumingMemoryBound(to: UInt8.self)
            let n = innerW * 4
            if strength >= 256 {
                memcpy(dst, enhanced, n)
            } else {
                let original = (fBase + (iy + row) * fStride + ix * 4).assumingMemoryBound(to: UInt8.self)
                for i in 0..<n {
                    let o = Int(original[i])
                    dst[i] = UInt8(clamping: o + ((Int(enhanced[i]) - o) * strength) / 256)
                }
            }
        }
    }

    // MARK: Буферы

    private func prepareBuffers(width: Int, height: Int, format: OSType) throws {
        let key = "\(width)x\(height)-\(format)"
        if key == bufferKey, frameBGRA != nil { return }

        let attrs: [String: Any] = [
            kCVPixelBufferIOSurfacePropertiesKey as String: [String: Any](),
            kCVPixelBufferMetalCompatibilityKey as String: true
        ]

        func makeBGRA() -> CVPixelBuffer? {
            var b: CVPixelBuffer?
            CVPixelBufferCreate(nil, width, height, OSType(kCVPixelFormatType_32BGRA), attrs as CFDictionary, &b)
            return b
        }
        guard let f = makeBGRA(), let r = makeBGRA() else { throw RenderError.frameCreationFailed }

        var poolAttrs = attrs
        poolAttrs[kCVPixelBufferPixelFormatTypeKey as String] = format
        poolAttrs[kCVPixelBufferWidthKey as String] = width
        poolAttrs[kCVPixelBufferHeightKey as String] = height
        var pool: CVPixelBufferPool?
        CVPixelBufferPoolCreate(nil, nil, poolAttrs as CFDictionary, &pool)
        guard let p = pool else { throw RenderError.frameCreationFailed }

        frameBGRA = f
        resultBGRA = r
        outputPool = p
        bufferKey = key
    }
}
