import CoreImage
import CoreImage.CIFilterBuiltins
import CoreGraphics
import AVFoundation
import CoreVideo

// MARK: - Параметры

struct GradeParams: Equatable {
    var exposure: Double = 0        // EV, -2...2
    var contrast: Double = 1        // 0.5...1.5
    var saturation: Double = 1      // 0...2
    var vibrance: Double = 0        // -1...1
    var warmth: Double = 0          // -100...100
    var tint: Double = 0            // -100...100
    var highlights: Double = 0      // 0...100 (приглушить света)
    var shadows: Double = 0         // -100...100
    var sharpness: Double = 0       // 0...2
    var vignette: Double = 0        // 0...1
    var denoise: Double = 0         // 0...1 сглаживание шума и текстур (края сохраняются)
    var clarity: Double = 0         // 0...1 локальный контраст («HDR-вид»)
    var curve: Double = 0           // 0...1 S-кривая (глубина)
    /// Сила автоподбора по референсу 0...1
    var matchStrength: Double = 1
}

/// Кривые по каналам R, G, B: y = a0 + a1·x + a2·x² + a3·x³
struct MatchCurve: Equatable {
    var red: [Double]
    var green: [Double]
    var blue: [Double]

    static let identityCoefficients: [Double] = [0, 1, 0, 0]
}

/// Потокобезопасное хранилище параметров: из него читает обработчик кадров плеера
final class GradeBox: @unchecked Sendable {
    private let lock = NSLock()
    private var params = GradeParams()
    private var match: MatchCurve?

    func set(params: GradeParams, match: MatchCurve?) {
        lock.lock()
        self.params = params
        self.match = match
        lock.unlock()
    }

    func get() -> (GradeParams, MatchCurve?) {
        lock.lock()
        defer { lock.unlock() }
        return (params, match)
    }
}

// MARK: - Применение коррекции

enum ColorGrader {

    /// Контекст без управления цветом: фильтры работают прямо по значениям кадра (как в обычных видеоредакторах),
    /// а не в линейном пространстве. Так результат совпадает со статистикой, снятой с картинок.
    static let context = CIContext(options: [
        .workingColorSpace: NSNull(),
        .outputColorSpace: NSNull()
    ])

    static func apply(to input: CIImage, params p: GradeParams, match: MatchCurve?) -> CIImage {
        var img = input
        let extent = input.extent

        // 0) Шумоподавление и сглаживание текстур (края сохраняются)
        if p.denoise > 0.001 {
            let f = CIFilter.noiseReduction()
            f.inputImage = img
            f.noiseLevel = Float(p.denoise * 0.08)
            f.sharpness = 0.6
            if let out = f.outputImage { img = out }
        }

        // 1) Подбор по референсу (кривые RGB)
        if let m = match, p.matchStrength > 0.001 {
            let f = CIFilter.colorPolynomial()
            f.inputImage = img
            f.redCoefficients = vector(m.red, strength: p.matchStrength)
            f.greenCoefficients = vector(m.green, strength: p.matchStrength)
            f.blueCoefficients = vector(m.blue, strength: p.matchStrength)
            f.alphaCoefficients = CIVector(x: 0, y: 1, z: 0, w: 0)
            if let out = f.outputImage { img = out }

            let clamp = CIFilter.colorClamp()
            clamp.inputImage = img
            clamp.minComponents = CIVector(x: 0, y: 0, z: 0, w: 0)
            clamp.maxComponents = CIVector(x: 1, y: 1, z: 1, w: 1)
            if let out = clamp.outputImage { img = out }
        }

        // 2) Экспозиция
        if abs(p.exposure) > 0.001 {
            let f = CIFilter.exposureAdjust()
            f.inputImage = img
            f.ev = Float(p.exposure)
            if let out = f.outputImage { img = out }
        }

        // 3) Теплота и оттенок
        if abs(p.warmth) > 0.1 || abs(p.tint) > 0.1 {
            let f = CIFilter.temperatureAndTint()
            f.inputImage = img
            f.neutral = CIVector(x: CGFloat(6500 + p.warmth * 25), y: CGFloat(p.tint))
            f.targetNeutral = CIVector(x: 6500, y: 0)
            if let out = f.outputImage { img = out }
        }

        // 4) Света и тени
        if p.highlights > 0.1 || abs(p.shadows) > 0.1 {
            let f = CIFilter.highlightShadowAdjust()
            f.inputImage = img
            f.highlightAmount = Float(1 - p.highlights / 100)
            f.shadowAmount = Float(p.shadows / 100)
            if let out = f.outputImage { img = out }
        }

        // 4b) S-кривая
        if p.curve > 0.001 {
            let k = p.curve * 0.1
            let f = CIFilter.toneCurve()
            f.inputImage = img
            f.point0 = CGPoint(x: 0, y: 0)
            f.point1 = CGPoint(x: 0.25, y: 0.25 - k)
            f.point2 = CGPoint(x: 0.5, y: 0.5)
            f.point3 = CGPoint(x: 0.75, y: 0.75 + k)
            f.point4 = CGPoint(x: 1, y: 1)
            if let out = f.outputImage { img = out }
        }

        // 5) Контраст и насыщенность
        if abs(p.contrast - 1) > 0.001 || abs(p.saturation - 1) > 0.001 {
            let f = CIFilter.colorControls()
            f.inputImage = img
            f.contrast = Float(p.contrast)
            f.saturation = Float(p.saturation)
            f.brightness = 0
            if let out = f.outputImage { img = out }
        }

        // 6) Живость
        if abs(p.vibrance) > 0.001 {
            let f = CIFilter.vibrance()
            f.inputImage = img
            f.amount = Float(p.vibrance)
            if let out = f.outputImage { img = out }
        }

        // 6b) Чёткость (локальный контраст): нерезкая маска с большим радиусом
        if p.clarity > 0.001 {
            let f = CIFilter.unsharpMask()
            f.inputImage = img
            f.radius = Float(max(extent.width, extent.height) * 0.012)
            f.intensity = Float(p.clarity * 0.9)
            if let out = f.outputImage { img = out }
        }

        // 7) Резкость
        if p.sharpness > 0.001 {
            let f = CIFilter.sharpenLuminance()
            f.inputImage = img
            f.sharpness = Float(p.sharpness)
            f.radius = 1.5
            if let out = f.outputImage { img = out }
        }

        // 8) Виньетка
        if p.vignette > 0.001 {
            let f = CIFilter.vignette()
            f.inputImage = img
            f.intensity = Float(p.vignette * 1.5)
            f.radius = 1.2
            if let out = f.outputImage { img = out }
        }

        return img.cropped(to: extent)
    }

    private static func vector(_ c: [Double], strength s: Double) -> CIVector {
        let id = MatchCurve.identityCoefficients
        let v = (0..<4).map { i in CGFloat(id[i] + s * (c[i] - id[i])) }
        return CIVector(x: v[0], y: v[1], z: v[2], w: v[3])
    }
}

// MARK: - Подбор по референсу

enum ColorMatcher {

    struct Histogram {
        var r = [Int](repeating: 0, count: 256)
        var g = [Int](repeating: 0, count: 256)
        var b = [Int](repeating: 0, count: 256)

        mutating func add(_ other: Histogram) {
            for i in 0..<256 {
                r[i] += other.r[i]
                g[i] += other.g[i]
                b[i] += other.b[i]
            }
        }
    }

    /// Гистограммы RGB по центральной части картинки (края с интерфейсом отбрасываем)
    static func histogram(of image: CGImage, centerFraction: Double = 0.8) -> Histogram? {
        let maxSide = 256.0
        let scale = min(1.0, maxSide / Double(max(image.width, image.height)))
        let w = max(8, Int(Double(image.width) * scale))
        let h = max(8, Int(Double(image.height) * scale))

        guard
            let space = CGColorSpace(name: CGColorSpace.sRGB),
            let ctx = CGContext(
                data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
                space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
            )
        else { return nil }

        ctx.interpolationQuality = .medium
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
        guard let data = ctx.data else { return nil }
        let px = data.bindMemory(to: UInt8.self, capacity: w * h * 4)

        let x0 = Int(Double(w) * (1 - centerFraction) / 2)
        let y0 = Int(Double(h) * (1 - centerFraction) / 2)
        let x1 = w - x0
        let y1 = h - y0

        var hist = Histogram()
        for y in y0..<y1 {
            for x in x0..<x1 {
                let i = (y * w + x) * 4
                hist.r[Int(px[i])] += 1
                hist.g[Int(px[i + 1])] += 1
                hist.b[Int(px[i + 2])] += 1
            }
        }
        return hist
    }

    /// Гистограммы по 5 кадрам видео
    static func histogram(from asset: AVAsset) async -> Histogram? {
        guard let duration = try? await asset.load(.duration), duration.seconds > 0 else { return nil }
        let generator = AVAssetImageGenerator(asset: asset)
        generator.appliesPreferredTrackTransform = true
        generator.maximumSize = CGSize(width: 512, height: 512)

        var total = Histogram()
        var got = 0
        for fraction in [0.1, 0.3, 0.5, 0.7, 0.9] {
            let t = CMTime(seconds: duration.seconds * fraction, preferredTimescale: 600)
            if let result = try? await generator.image(at: t), let h = histogram(of: result.image) {
                total.add(h)
                got += 1
            }
        }
        return got > 0 ? total : nil
    }

    /// Подбирает кривые так, чтобы распределение яркости каждого канала в видео совпало с референсом
    static func fit(source: Histogram, reference: Histogram) -> MatchCurve {
        MatchCurve(
            red: fitChannel(source.r, reference.r),
            green: fitChannel(source.g, reference.g),
            blue: fitChannel(source.b, reference.b)
        )
    }

    private static func fitChannel(_ s: [Int], _ r: [Int]) -> [Double] {
        let identity = MatchCurve.identityCoefficients
        let n = 32
        guard let xs = quantiles(s, count: n), let ys = quantiles(r, count: n) else { return identity }
        for degree in [3, 2, 1] {
            if let c = polyFit(xs, ys, degree: degree), isSane(c) {
                return c + [Double](repeating: 0, count: 4 - c.count)
            }
        }
        return identity
    }

    private static func quantiles(_ hist: [Int], count n: Int) -> [Double]? {
        let total = hist.reduce(0, +)
        guard total > 0 else { return nil }
        var out = [Double]()
        var cumulative = 0
        var bin = 0
        for i in 0..<n {
            let target = (Double(i) + 0.5) / Double(n) * Double(total)
            while bin < 255 && Double(cumulative + hist[bin]) < target {
                cumulative += hist[bin]
                bin += 1
            }
            out.append(Double(bin) / 255.0)
        }
        return out
    }

    /// Метод наименьших квадратов (метод Гаусса–Жордана)
    private static func polyFit(_ x: [Double], _ y: [Double], degree d: Int) -> [Double]? {
        let n = d + 1
        var a = [[Double]](repeating: [Double](repeating: 0, count: n + 1), count: n)
        for k in 0..<x.count {
            var powers = [Double](repeating: 1, count: 2 * n)
            for p in 1..<(2 * n) { powers[p] = powers[p - 1] * x[k] }
            for i in 0..<n {
                for j in 0..<n { a[i][j] += powers[i + j] }
                a[i][n] += y[k] * powers[i]
            }
        }
        for col in 0..<n {
            var pivot = col
            for r in (col + 1)..<n where abs(a[r][col]) > abs(a[pivot][col]) { pivot = r }
            if abs(a[pivot][col]) < 1e-12 { return nil }
            a.swapAt(col, pivot)
            for r in 0..<n where r != col {
                let f = a[r][col] / a[col][col]
                for c in col...n { a[r][c] -= f * a[col][c] }
            }
        }
        return (0..<n).map { a[$0][n] / a[$0][$0] }
    }

    /// Кривая должна быть возрастающей и не вылетать за разумные пределы
    private static func isSane(_ c: [Double]) -> Bool {
        var previous = -Double.infinity
        for k in 0...64 {
            let t = Double(k) / 64
            var v = 0.0
            var power = 1.0
            for coefficient in c {
                v += coefficient * power
                power *= t
            }
            if v < -0.15 || v > 1.15 { return false }
            if v < previous - 0.002 { return false }
            previous = v
        }
        return true
    }
}


// MARK: - Пресеты

extension GradeParams {
    /// «HDR-вид» для игровых записей: локальный контраст, резкие края, сглаженные текстуры, насыщенный цвет
    static var hdrGame: GradeParams {
        var p = GradeParams()
        p.denoise = 0.30
        p.clarity = 0.55
        p.sharpness = 0.7
        p.curve = 0.45
        p.contrast = 1.08
        p.saturation = 1.12
        p.vibrance = 0.35
        p.highlights = 15
        p.shadows = 30
        return p
    }

    /// Более деликатный вариант: чище и чётче, без сильного изменения цвета
    static var crisp: GradeParams {
        var p = GradeParams()
        p.denoise = 0.20
        p.clarity = 0.30
        p.sharpness = 0.5
        p.curve = 0.20
        p.vibrance = 0.15
        return p
    }
}

// MARK: - Общий цвет для вкладки «Рендер»

struct GradeSnapshot {
    var params: GradeParams
    var match: MatchCurve?
}

/// Сюда вкладка «Цвет» кладёт текущие настройки, а вкладка «Рендер» применяет их за один проход
enum GradeStore {
    static let box = GradeBox()

    static func snapshot() -> GradeSnapshot {
        let (p, m) = box.get()
        return GradeSnapshot(params: p, match: m)
    }

    static var isConfigured: Bool {
        let s = snapshot()
        return s.params != GradeParams() || s.match != nil
    }
}

/// Применяет цвет к кадрам внутри рендера (кадр YCbCr → кадр YCbCr того же формата и размера)
final class GradeStage {
    private let snapshot: GradeSnapshot
    private var pool: CVPixelBufferPool?
    private var key = ""

    init(snapshot: GradeSnapshot) {
        self.snapshot = snapshot
    }

    func apply(_ src: CVPixelBuffer) throws -> CVPixelBuffer {
        let w = CVPixelBufferGetWidth(src)
        let h = CVPixelBufferGetHeight(src)
        let format = CVPixelBufferGetPixelFormatType(src)
        let newKey = "\(w)x\(h)-\(format)"

        if pool == nil || key != newKey {
            var out: CVPixelBufferPool?
            CVPixelBufferPoolCreate(
                nil, nil,
                [
                    kCVPixelBufferPixelFormatTypeKey as String: format,
                    kCVPixelBufferWidthKey as String: w,
                    kCVPixelBufferHeightKey as String: h,
                    kCVPixelBufferIOSurfacePropertiesKey as String: [String: Any](),
                    kCVPixelBufferMetalCompatibilityKey as String: true
                ] as CFDictionary,
                &out
            )
            guard let p = out else { throw RenderError.frameCreationFailed }
            pool = p
            key = newKey
        }
        guard let pool else { throw RenderError.frameCreationFailed }

        var dstOut: CVPixelBuffer?
        CVPixelBufferPoolCreatePixelBuffer(nil, pool, &dstOut)
        guard let dst = dstOut else { throw RenderError.frameCreationFailed }

        CVBufferPropagateAttachments(src, dst)
        let graded = ColorGrader.apply(to: CIImage(cvPixelBuffer: src), params: snapshot.params, match: snapshot.match)
        ColorGrader.context.render(graded, to: dst)
        return dst
    }
}
