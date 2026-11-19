import AppKit
import CoreImage
import CoreText
import Foundation

/// Renders caption images with Core Text and composites them over video
/// frames. The same code path drives the in-app preview and the export, so
/// the preview matches the burned result.
final class SubtitleFrameCompositor: @unchecked Sendable {
    private let cues: [SubtitleCue]
    private let style: SubtitleBurnStyle
    private let maxCueDuration: TimeInterval
    private let lock = NSLock()
    private var cache: [CacheKey: CIImage] = [:]
    private var cacheOrder: [CacheKey] = []
    private static let cacheLimit = 12

    private struct CacheKey: Hashable {
        let index: Int
        let width: Int
        let height: Int
    }

    init(cues: [SubtitleCue], style: SubtitleBurnStyle) {
        self.cues = cues.sorted { $0.startTime < $1.startTime }
        self.style = style.clamped()
        self.maxCueDuration = self.cues.map { $0.endTime - $0.startTime }.max() ?? 0
    }

    /// Indices of cues visible at `time`, in start order.
    func activeCueIndices(at time: TimeInterval) -> [Int] {
        guard !cues.isEmpty else { return [] }
        var low = 0, high = cues.count
        while low < high {
            let mid = (low + high) / 2
            if cues[mid].startTime <= time { low = mid + 1 } else { high = mid }
        }
        var result: [Int] = []
        var index = low - 1
        while index >= 0, cues[index].startTime >= time - maxCueDuration {
            if cues[index].startTime <= time, time < cues[index].endTime { result.append(index) }
            index -= 1
        }
        return result.reversed()
    }

    func composite(_ source: CIImage, at time: TimeInterval, renderSize: CGSize) -> CIImage {
        let indices = activeCueIndices(at: time)
        guard !indices.isEmpty, renderSize.width > 0, renderSize.height > 0 else { return source }
        let metrics = SubtitleLayoutMetrics(renderSize: renderSize, style: style)
        let images = indices.compactMap { cueImage(index: $0, renderSize: renderSize) }
        // Stack overlapping cues: the newest cue sits at the anchored edge.
        var output = source
        var offset: CGFloat = 0
        for image in images.reversed() {
            let extent = image.extent
            let x = ((renderSize.width - extent.width) / 2).rounded()
            let y: CGFloat
            switch style.position {
            case .bottom:
                y = metrics.margin - metrics.padding + metrics.backgroundInsets.height + offset
            case .top:
                y = renderSize.height - metrics.margin + metrics.padding - metrics.backgroundInsets.height - extent.height - offset
            }
            output = image.transformed(by: CGAffineTransform(translationX: x, y: y.rounded())).composited(over: output)
            offset += extent.height - 2 * metrics.padding + 2 * metrics.backgroundInsets.height + metrics.stackGap
        }
        return output.cropped(to: source.extent)
    }

    private func cueImage(index: Int, renderSize: CGSize) -> CIImage? {
        let key = CacheKey(index: index, width: Int(renderSize.width), height: Int(renderSize.height))
        lock.lock()
        if let cached = cache[key] { lock.unlock(); return cached }
        lock.unlock()
        guard let cgImage = SubtitleCueRasterizer.render(text: cues[index].text, renderSize: renderSize, style: style) else {
            return nil
        }
        let image = CIImage(cgImage: cgImage)
        lock.lock()
        cache[key] = image
        cacheOrder.append(key)
        if cacheOrder.count > Self.cacheLimit {
            cache[cacheOrder.removeFirst()] = nil
        }
        lock.unlock()
        return image
    }
}

struct SubtitleLayoutMetrics {
    let fontSize: CGFloat
    let margin: CGFloat
    let maxTextWidth: CGFloat
    /// Transparent padding around the text so shadows and the background are not clipped.
    let padding: CGFloat
    let backgroundInsets: CGSize
    let shadowUnit: CGFloat
    let stackGap: CGFloat

    init(renderSize: CGSize, style: SubtitleBurnStyle) {
        let shortSide = max(min(renderSize.width, renderSize.height), 1)
        fontSize = max((shortSide * style.fontSizePercent / 100).rounded(), 8)
        margin = shortSide * style.marginPercent / 100
        maxTextWidth = renderSize.width * 0.9
        // Shadow "width" level 0–10 maps to a blur unit proportional to the font size.
        shadowUnit = fontSize * style.shadowWidth / 30
        backgroundInsets = style.backgroundEnabled
            ? CGSize(width: (fontSize * 0.4).rounded(), height: (fontSize * 0.2).rounded())
            : .zero
        padding = (max(shadowUnit * 2.6, 2) + max(backgroundInsets.width, backgroundInsets.height)).rounded(.up)
        stackGap = fontSize * 0.25
    }
}

enum SubtitleCueRasterizer {
    /// Renders one cue as a tightly sized RGBA image (text, optional background, layered soft shadow).
    static func render(text: String, renderSize: CGSize, style: SubtitleBurnStyle) -> CGImage? {
        let metrics = SubtitleLayoutMetrics(renderSize: renderSize, style: style)
        let font = style.font(size: metrics.fontSize)
        let paragraph = NSMutableParagraphStyle()
        paragraph.alignment = .center
        paragraph.lineBreakMode = .byWordWrapping
        paragraph.lineHeightMultiple = 1.05
        let attributed = NSAttributedString(string: text, attributes: [
            .font: font,
            .foregroundColor: NSColor.white,
            .paragraphStyle: paragraph,
        ])
        let framesetter = CTFramesetterCreateWithAttributedString(attributed)
        let constraint = CGSize(width: metrics.maxTextWidth, height: .greatestFiniteMagnitude)
        let suggested = CTFramesetterSuggestFrameSizeWithConstraints(framesetter, CFRange(location: 0, length: 0), nil, constraint, nil)
        let textSize = CGSize(width: ceil(min(suggested.width, metrics.maxTextWidth)), height: ceil(suggested.height))
        guard textSize.width > 0, textSize.height > 0 else { return nil }

        let width = Int(textSize.width + 2 * metrics.padding)
        let height = Int(textSize.height + 2 * metrics.padding)
        guard let context = CGContext(
            data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpace(name: CGColorSpace.sRGB)!,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return nil }

        let textRect = CGRect(origin: CGPoint(x: metrics.padding, y: metrics.padding), size: textSize)
        if style.backgroundEnabled, style.backgroundOpacity > 0 {
            let box = textRect.insetBy(dx: -metrics.backgroundInsets.width, dy: -metrics.backgroundInsets.height)
            let radius = metrics.fontSize * 0.25
            context.setFillColor(CGColor(gray: 0, alpha: style.backgroundOpacity))
            context.addPath(CGPath(roundedRect: box, cornerWidth: radius, cornerHeight: radius, transform: nil))
            context.fillPath()
        }

        // Use a frame wider than the text so centered lines are not clipped by rounding.
        let path = CGPath(rect: textRect.insetBy(dx: -1, dy: 0), transform: nil)
        let frame = CTFramesetterCreateFrame(framesetter, CFRange(location: 0, length: 0), path, nil)
        let unit = metrics.shadowUnit
        if unit > 0 {
            let offset = CGSize(width: 0, height: -unit * 0.1)
            // Wide, soft outer falloff.
            context.saveGState()
            context.setShadow(offset: offset, blur: unit * 1.2, color: style.shadowColor.cgColor.copy(alpha: 0.55))
            CTFrameDraw(frame, context)
            context.restoreGState()
            // Tight, dense inner shadow that keeps letter edges crisp on bright footage.
            context.saveGState()
            context.setShadow(offset: offset, blur: unit * 0.35, color: style.shadowColor.cgColor.copy(alpha: 0.85))
            CTFrameDraw(frame, context)
            context.restoreGState()
        }
        CTFrameDraw(frame, context)
        return context.makeImage()
    }
}
