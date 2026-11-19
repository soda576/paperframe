import AppKit
import CoreText
import AVFoundation
import ImageIO

final class PaperStyle {
    private let latin = PaperStyle.load("CourierPrime-Regular") ?? "Courier"
    private let chinese = PaperStyle.load("LXGWNeoZhiSong") ?? "SongtiSC-Regular"
    private let original = PaperStyle.load("ipaexm") ?? "SongtiSC-Regular"
    var usesOriginal = false
    var usesSystem = false
    private var fonts: [String: NSFont] = [:]
    private let strike = PaperStyle.sound("strike")
    private let ring = PaperStyle.sound("return")
    private let returnMovement = PaperStyle.sound("return")

    static func load(_ name: String) -> String? {
        guard let url = Bundle.main.url(forResource: name, withExtension: "ttf"),
              let descriptor = (CTFontManagerCreateFontDescriptorsFromURL(url as CFURL) as? [CTFontDescriptor])?.first
        else { return nil }
        CTFontManagerRegisterFontsForURL(url as CFURL, .process, nil)
        return CTFontCopyPostScriptName(CTFontCreateWithFontDescriptor(descriptor, 16, nil)) as String
    }

    private static func sound(_ name: String) -> AVAudioPlayer? {
        guard let url = Bundle.main.url(forResource: name, withExtension: "wav") else { return nil }
        let player = try? AVAudioPlayer(contentsOf: url)
        player?.prepareToPlay()
        return player
    }

    func play(returning: Bool = false) {
        if returning {
            ring?.stop()
            ring?.currentTime = 0
            ring?.volume = 0.45
            ring?.play()
            returnMovement?.stop()
            returnMovement?.currentTime = 1.75
            returnMovement?.enableRate = true
            returnMovement?.rate = 1.65
            returnMovement?.volume = 0.55
            returnMovement?.play()
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.46) { [weak self] in
                if self?.ring?.currentTime ?? 0 > 0.35 { self?.ring?.stop() }
                if self?.returnMovement?.currentTime ?? 0 > 2.3 { self?.returnMovement?.stop() }
            }
        } else {
            strike?.currentTime = 0.009
            strike?.volume = 0.55
            strike?.play()
        }
    }

    func font(latin isLatin: Bool, size: CGFloat) -> NSFont {
        if usesSystem { return .systemFont(ofSize: size, weight: .regular) }
        let name = isLatin ? latin : usesOriginal ? original : chinese
        let key = "\(name)-\(size)"
        if let cached = fonts[key] { return cached }
        let base = NSFont(name: name, size: size) ?? .systemFont(ofSize: size)
        var transform = AffineTransform()
        transform.scale(x: size * 0.88, y: size)
        let font = NSFont(descriptor: base.fontDescriptor, textTransform: transform) ?? base
        fonts[key] = font
        return font
    }

    private static let lightInk = imprint(night: true)
    private static let darkInk = imprint(night: false)

    func text(_ string: String, size: CGFloat = 19, ink: NSColor, pressed: Bool = false,
              tinted: Bool = false) -> NSAttributedString {
        let isLight = (ink.usingColorSpace(.deviceGray)?.whiteComponent ?? 0) > 0.5
        let pigment = pressed && !tinted && !usesSystem ? (isLight ? Self.lightInk : Self.darkInk) : ink
        let result = NSMutableAttributedString()
        var start = string.startIndex
        var previous = string.first?.isASCII
        for index in string.indices {
            let latin = string[index].isASCII
            if latin != previous {
                result.append(NSAttributedString(string: String(string[start..<index]), attributes: [
                    .font: font(latin: previous == true, size: size), .foregroundColor: pigment
                ]))
                start = index
                previous = latin
            }
        }
        result.append(NSAttributedString(string: String(string[start...]), attributes: [
            .font: font(latin: previous == true, size: size), .foregroundColor: pigment
        ]))
        return result
    }

    private static func imprint(night: Bool) -> NSColor {
        let side = 72
        let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: side, pixelsHigh: side,
                                      bitsPerSample: 8, samplesPerPixel: 3, hasAlpha: false,
                                      isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: side * 3, bitsPerPixel: 24)!
        let bytes = bitmap.bitmapData!
        var seed: UInt32 = night ? 15_357 : 8_759
        for y in 0..<side {
            for x in 0..<side {
                seed = seed &* 1_664_525 &+ 1_013_904_223
                let noise = Double(seed >> 24) / 255
                let dryFiber = noise > 0.88 ? 0.11 : 0
                let mottling = 0.027 * sin(Double(x) * 0.73 + Double(y) * 0.59)
                let value = night ? 0.73 + 0.10 * (noise - 0.5) + mottling - dryFiber
                                  : 0.125 + 0.10 * noise + mottling + dryFiber
                let offset = y * bitmap.bytesPerRow + 3 * x
                for channel in 0..<3 { bytes[offset + channel] = UInt8(clamping: Int(value * 255)) }
            }
        }
        let image = NSImage(size: NSSize(width: 36, height: 36))
        bitmap.size = image.size
        image.addRepresentation(bitmap)
        return NSColor(patternImage: image)
    }
}

private extension Character {
    var isASCII: Bool { unicodeScalars.allSatisfy(\.isASCII) }
}

class PaperSurface: NSView {
    static let daylightPaper = 0xd8e1e6
    static let lowLightPaper = 0x303334
    static let glassInk = PaperSwatch.rgb(0xf6f8fa)

    var night = false { didSet { needsDisplay = true } }
    var glass = false { didSet { if oldValue != glass { needsDisplay = true } } }
    var paperTint: NSColor? { didSet { needsDisplay = true } }
    var lampTint: NSColor? { didSet { needsDisplay = true } }
    var lampIntensity: CGFloat = 1 { didSet { needsDisplay = true } }
    var lampLevel: CGFloat = 1 { didSet { if oldValue != lampLevel { needsDisplay = true } } }
    var lampRange: CGFloat = 1 { didSet { needsDisplay = true } }
    var mechanismStyle = MechanismStyle.signal { didSet { if oldValue != mechanismStyle { needsDisplay = true } } }
    var lampOrigin: CGPoint? { didSet { if oldValue != lampOrigin { needsDisplay = true } } }
    var onResize: (() -> Void)?
    var softGrain = false
    var paintsSurface = true
    private static let grainWidth = 830
    private static let grainHeight = 580
    private static let paperGrain: [Int8]? = {
        guard let url = Bundle.main.url(forResource: "Paper001-Relief", withExtension: "jpg"),
              let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let image = CGImageSourceCreateImageAtIndex(source, 0, nil),
              let relief = image.cropping(to: CGRect(x: 70, y: 10, width: grainWidth, height: grainHeight)),
              let context = CGContext(data: nil, width: grainWidth, height: grainHeight, bitsPerComponent: 8,
                                      bytesPerRow: grainWidth, space: CGColorSpaceCreateDeviceGray(),
                                      bitmapInfo: CGImageAlphaInfo.none.rawValue),
              let data = context.data?.assumingMemoryBound(to: UInt8.self)
        else { return nil }
        context.draw(relief, in: CGRect(x: 0, y: 0, width: grainWidth, height: grainHeight))
        let buffer = UnsafeBufferPointer(start: data, count: grainWidth * grainHeight)
        let average = buffer.reduce(0) { $0 + Int($1) } / buffer.count
        var seed: UInt32 = 8_759
        func next() -> UInt32 {
            seed = seed &* 1_664_525 &+ 1_013_904_223
            return seed
        }
        var grain = buffer.map { level in
            Int8((Int(level) - average) / 15 + Int(next() >> 29) - 3)
        }
        for _ in 0..<690 {
            let index = Int(next()) % (grain.count - grainWidth - 1)
            let depth = 14 + Int(next() >> 26)
            grain[index] = Int8(clamping: Int(grain[index]) - depth)
            if depth > 24 {
                let tail = index + grainWidth + 1
                grain[tail] = Int8(clamping: Int(grain[tail]) - depth / 3)
            }
        }
        withExtendedLifetime(context) {}
        return grain
    }()
    private static let whitePaper = texture(base: daylightPaper, contrast: 1)
    private static let blackPaper = texture(base: lowLightPaper, contrast: 0.48)
    private static let softWhite = texture(base: daylightPaper, contrast: 0.91)
    private static let softBlack = texture(base: lowLightPaper, contrast: 0.39)
    private static let litPaper = texture(base: 0xcacacd, contrast: 0.9)
    private static let signalLitPaper = texture(base: 0xe2e1d9, contrast: 1.08)
    private static let glow = makeGlow()
    private static let signalGlow = makeGlow(signal: true)

    override func setFrameSize(_ newSize: NSSize) {
        let changed = newSize != frame.size
        super.setFrameSize(newSize)
        if changed { onResize?() }
    }

    override func draw(_ dirtyRect: NSRect) {
        guard paintsSurface, let context = NSGraphicsContext.current?.cgContext else { return }
        context.saveGState()
        defer { context.restoreGState() }
        context.clip(to: bounds)
        let paper = night ? (softGrain ? Self.softBlack : Self.blackPaper)
                          : (softGrain ? Self.softWhite : Self.whitePaper)
        let width = CGFloat(Self.grainWidth), height = CGFloat(Self.grainHeight)
        let scale = max(bounds.width / width, bounds.height / height, 0.73)
        let mapped = CGRect(x: bounds.midX - width * scale / 2, y: bounds.midY - height * scale / 2,
                            width: width * scale, height: height * scale)
        if glass {
            PaperSwatch.rgb(0x0c1016).withAlphaComponent(night ? 0.69 : 0.58).setFill()
            dirtyRect.fill()
        } else {
            if let paper {
                context.draw(paper, in: mapped)
            } else {
                PaperSwatch.paper[0].color(night: night).setFill()
                dirtyRect.fill()
            }
            if let paperTint {
                paperTint.withAlphaComponent(night ? 0.17 : 0.44).setFill()
                dirtyRect.fill()
            }
        }
        guard night, let lampOrigin, lampIntensity > 0, lampLevel > 0 else { return }
        let signal = mechanismStyle == .signal
        let glow = signal ? Self.signalGlow : Self.glow
        let beamWidth = CGFloat(glow.width) * lampRange
        let field = CGRect(x: lampOrigin.x - beamWidth / 2, y: lampOrigin.y - 15 * lampRange,
                           width: beamWidth, height: CGFloat(glow.height) * lampRange)
        guard field.intersects(dirtyRect) else { return }
        context.saveGState()
        context.clip(to: field)
        context.setAlpha(lampIntensity * lampLevel * (glass ? 0.50 : 1))
        if let lit = signal ? Self.signalLitPaper : Self.litPaper {
            context.beginTransparencyLayer(auxiliaryInfo: nil)
            context.draw(glow, in: field)
            context.setBlendMode(.sourceIn)
            context.draw(lit, in: mapped)
            if let tint = lampTint ?? (signal ? PaperSwatch.rgb(0xf6dfbb) : nil) {
                context.setBlendMode(.sourceAtop)
                context.setFillColor(tint.withAlphaComponent(lampTint == nil ? 0.13 : 0.3).cgColor)
                context.fill(field)
            }
            context.setBlendMode(.normal)
            context.endTransparencyLayer()
        } else {
            context.draw(glow, in: field)
        }
        context.restoreGState()
    }

    private static func texture(base: Int, contrast: Double) -> CGImage? {
        guard let paperGrain, let space = CGColorSpace(name: CGColorSpace.sRGB) else { return nil }
        var pixels = [UInt8](repeating: 255, count: paperGrain.count * 4)
        let red = (base >> 16) & 255, green = (base >> 8) & 255, blue = base & 255
        for (index, fiber) in paperGrain.enumerated() {
            let grain = Int((Double(fiber) * contrast).rounded())
            pixels[index * 4] = UInt8(clamping: red + grain)
            pixels[index * 4 + 1] = UInt8(clamping: green + grain)
            pixels[index * 4 + 2] = UInt8(clamping: blue + grain)
        }
        guard let provider = CGDataProvider(data: Data(pixels) as CFData) else { return nil }
        return CGImage(width: grainWidth, height: grainHeight, bitsPerComponent: 8, bitsPerPixel: 32,
                       bytesPerRow: grainWidth * 4, space: space,
                       bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.noneSkipLast.rawValue),
                       provider: provider, decode: nil, shouldInterpolate: true, intent: .defaultIntent)
    }

    private static func makeGlow(signal: Bool = false) -> CGImage {
        let width = signal ? 392 : 338
        let height = signal ? 181 : 159
        var pixels = [UInt8](repeating: 0, count: width * height * 4)
        func smoothFade(_ value: Double) -> Double {
            let t = min(1, max(0, value))
            return t * t * (3 - 2 * t)
        }
        for row in 0..<height {
            let lift = Double(height - 1 - row) - 15
            let rise = max(0, lift)
            for column in 0..<width {
                let across = Double(column - width / 2)
                let opacity: Double
                if signal {
                    let opening = 9 + rise * 1.97
                    let feather = 6 + rise * 0.43
                    let fan = smoothFade((opening + feather - abs(across)) / (2 * feather))
                    let core = fan * exp(-pow(across / (30 + rise * 1.87), 2) * 0.55
                                         - pow((rise - 10) / 69, 2))
                    let highlight = fan * exp(-pow((rise - 6) / 10, 2)) * 0.48
                    let scatter = exp(-pow(across / (23 + rise * 1.12), 2) - pow((lift - 50) / 71, 2))
                    let side = smoothFade((Double(width / 2) - abs(across)) / 42)
                    let top = smoothFade((Double(height - 16) - lift) / 46)
                    let foot = smoothFade((lift + 4) / 10)
                    opacity = (core * 0.34 + highlight + scatter * 0.12) * side * top * foot
                } else {
                    let spread = 17 + rise * 1.03
                    let sideFade = min(1, max(0, (Double(width / 2) - abs(across)) / 28))
                    let endFade = min(1, max(0, (144 - lift) / 30))
                    let near = exp(-pow(across / spread, 2) * 1.18 - pow(lift / (lift > 0 ? 41 : 5.2), 2))
                    let spill = exp(-pow(across / 83, 2) - pow((lift - 42) / 45, 2)) * 0.21
                    let riseFade = min(1, max(0, (lift + 13) / 13))
                    opacity = (near * 0.53 + spill) * sideFade * endFade * riseFade
                }
                let alpha = UInt8(clamping: Int(opacity * 255))
                let offset = (row * width + column) * 4
                for channel in 0..<4 { pixels[offset + channel] = alpha }
            }
        }
        return CGImage(width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32,
                       bytesPerRow: width * 4, space: CGColorSpaceCreateDeviceRGB(),
                       bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
                       provider: CGDataProvider(data: Data(pixels) as CFData)!, decode: nil,
                       shouldInterpolate: true, intent: .defaultIntent)!
    }
}

func gray(_ value: CGFloat, alpha: CGFloat = 1) -> NSColor {
    NSColor(srgbRed: value, green: value, blue: value, alpha: alpha)
}
