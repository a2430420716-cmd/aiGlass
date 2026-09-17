import UIKit
import ImageIO

/// 按眼镜设置里的图片水印样式，在导入照片上绘制水印。
enum PhotoWatermarkApplier {
    enum Style: Int, CaseIterable {
        case overlay = 1
        case footerBar = 2
        case footerMeta = 3

        var assetPreviewName: String {
            switch self {
            case .overlay: return "watermark_style_1"
            case .footerBar: return "watermark_style_2"
            case .footerMeta: return "watermark_style_3"
            }
        }
    }

    /// 未开启水印则原样返回；失败也回退原图，不阻断导入。
    static func applyIfNeeded(_ imageData: Data, capturedAt: Date = Date()) -> Data {
        guard AppSettings.imageWatermarkEnabled else { return imageData }
        guard let style = Style(rawValue: AppSettings.imageWatermarkStyle) else { return imageData }
        do {
            return try apply(imageData, style: style, capturedAt: capturedAt)
        } catch {
            print("[Watermark] apply failed style=\(style.rawValue): \(error.localizedDescription)")
            return imageData
        }
    }

    static func apply(_ imageData: Data, style: Style, capturedAt: Date) throws -> Data {
        guard let image = UIImage(data: imageData), image.size.width > 0, image.size.height > 0 else {
            throw WatermarkError.invalidImage
        }
        let stamped: UIImage
        switch style {
        case .overlay:
            stamped = drawOverlayStyle(image, date: capturedAt)
        case .footerBar:
            stamped = drawFooterBarStyle(image, date: capturedAt)
        case .footerMeta:
            stamped = drawFooterMetaStyle(image, date: capturedAt, sourceData: imageData)
        }
        guard let jpeg = stamped.jpegData(compressionQuality: 0.92) else {
            throw WatermarkError.encodeFailed
        }
        return jpeg
    }

    // MARK: - Style 1：左下角白色文字叠在图上

    private static func drawOverlayStyle(_ image: UIImage, date: Date) -> UIImage {
        let size = image.size
        let format = UIGraphicsImageRendererFormat()
        format.scale = image.scale
        format.opaque = true
        let renderer = UIGraphicsImageRenderer(size: size, format: format)
        return renderer.image { _ in
            image.draw(in: CGRect(origin: .zero, size: size))

            let padX = size.width * 0.035
            let padY = size.height * 0.035
            let brandFontSize = max(14, min(size.width, size.height) * 0.028)
            let dateFontSize = brandFontSize * 0.55

            let brand = brandAttributedString(
                fontSize: brandFontSize,
                brandColor: .white,
                suffixColor: UIColor.white.withAlphaComponent(0.95)
            )
            let time = NSAttributedString(
                string: formatDate(date),
                attributes: [
                    .font: UIFont.systemFont(ofSize: dateFontSize, weight: .regular),
                    .foregroundColor: UIColor.white.withAlphaComponent(0.92)
                ]
            )

            let brandSize = brand.size()
            let timeSize = time.size()
            let brandOrigin = CGPoint(x: padX, y: size.height - padY - timeSize.height - 4 - brandSize.height)
            let timeOrigin = CGPoint(x: padX, y: size.height - padY - timeSize.height)
            brand.draw(at: brandOrigin)
            time.draw(at: timeOrigin)
        }
    }

    // MARK: - Style 2：底部白条，左品牌右时间

    private static func drawFooterBarStyle(_ image: UIImage, date: Date) -> UIImage {
        let photoSize = image.size
        let barHeight = max(36, photoSize.height * 0.085)
        let canvas = CGSize(width: photoSize.width, height: photoSize.height + barHeight)
        let format = UIGraphicsImageRendererFormat()
        format.scale = image.scale
        format.opaque = true
        let renderer = UIGraphicsImageRenderer(size: canvas, format: format)
        return renderer.image { ctx in
            UIColor.white.setFill()
            ctx.fill(CGRect(origin: .zero, size: canvas))
            image.draw(in: CGRect(origin: .zero, size: photoSize))

            let padX = photoSize.width * 0.04
            let brandFontSize = max(13, min(photoSize.width, photoSize.height) * 0.026)
            let dateFontSize = brandFontSize * 0.85

            let brand = brandAttributedString(
                fontSize: brandFontSize,
                brandColor: .black,
                suffixColor: UIColor.black.withAlphaComponent(0.85)
            )
            let time = NSAttributedString(
                string: formatDate(date),
                attributes: [
                    .font: UIFont.systemFont(ofSize: dateFontSize, weight: .regular),
                    .foregroundColor: UIColor.black.withAlphaComponent(0.75)
                ]
            )

            let brandSize = brand.size()
            let timeSize = time.size()
            let barMidY = photoSize.height + (barHeight - brandSize.height) / 2
            brand.draw(at: CGPoint(x: padX, y: barMidY))
            time.draw(at: CGPoint(
                x: canvas.width - padX - timeSize.width,
                y: photoSize.height + (barHeight - timeSize.height) / 2
            ))
        }
    }

    // MARK: - Style 3：四周白框，左品牌，右参数+时间（对齐 Android drawFramedStyle）

    private static func drawFooterMetaStyle(_ image: UIImage, date: Date, sourceData: Data) -> UIImage {
        let photoSize = image.size
        let border = max(20, photoSize.width / 24)
        let bottom = max(110, photoSize.height / 5)
        let canvas = CGSize(
            width: photoSize.width + border * 2,
            height: photoSize.height + border + bottom
        )
        let format = UIGraphicsImageRendererFormat()
        format.scale = image.scale
        format.opaque = true
        let renderer = UIGraphicsImageRenderer(size: canvas, format: format)
        return renderer.image { ctx in
            UIColor.white.setFill()
            ctx.fill(CGRect(origin: .zero, size: canvas))
            image.draw(in: CGRect(
                x: border,
                y: border,
                width: photoSize.width,
                height: photoSize.height
            ))

            let titleFont = UIFont.systemFont(
                ofSize: max(26, photoSize.width / 20),
                weight: .bold
            )
            let smallFont = UIFont.systemFont(
                ofSize: max(13, photoSize.width / 58),
                weight: .regular
            )
            let textAttributes: [NSAttributedString.Key: Any] = [
                .font: smallFont,
                .foregroundColor: UIColor.black
            ]
            let brand = NSAttributedString(
                string: "MOCO AI Glasses",
                attributes: [
                    .font: titleFont,
                    .foregroundColor: UIColor.black
                ]
            )
            let meta = NSAttributedString(
                string: exifSummary(from: sourceData),
                attributes: textAttributes
            )
            let time = NSAttributedString(
                string: formatDate(date),
                attributes: textAttributes
            )

            // Android Canvas.drawText 使用 baseline；这里按相同基线计算。
            let titleBaseline = border + photoSize.height + bottom * 0.58
            brand.draw(at: CGPoint(x: border, y: titleBaseline - titleFont.ascender))

            let metaSize = meta.size()
            let timeSize = time.size()
            let rightX = canvas.width - border
            let metaBaseline = titleBaseline - smallFont.pointSize - 4
            let timeBaseline = titleBaseline + smallFont.pointSize + 6
            meta.draw(at: CGPoint(
                x: rightX - metaSize.width,
                y: metaBaseline - smallFont.ascender
            ))
            time.draw(at: CGPoint(
                x: rightX - timeSize.width,
                y: timeBaseline - smallFont.ascender
            ))
        }
    }

    // MARK: - Shared

    private static func brandAttributedString(
        fontSize: CGFloat,
        brandColor: UIColor,
        suffixColor: UIColor
    ) -> NSAttributedString {
        let text = NSMutableAttributedString(
            string: "MOCO",
            attributes: [
                .font: UIFont.systemFont(ofSize: fontSize, weight: .bold),
                .foregroundColor: brandColor
            ]
        )
        text.append(NSAttributedString(
            string: " AI Glasses",
            attributes: [
                .font: UIFont.systemFont(ofSize: fontSize, weight: .regular),
                .foregroundColor: suffixColor
            ]
        ))
        return text
    }

    private static func formatDate(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy.MM.dd HH:mm"
        return formatter.string(from: date)
    }

    /// 尽量读 EXIF；没有则用设计稿默认参数。
    private static func exifSummary(from data: Data) -> String {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              let props = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let exif = props[kCGImagePropertyExifDictionary] as? [CFString: Any] else {
            return "16mm  f/2.5  1/250s  ISO 50"
        }

        var parts: [String] = []
        if let focal = exif[kCGImagePropertyExifFocalLength] as? Double {
            parts.append(String(format: "%.0fmm", focal))
        } else {
            parts.append("16mm")
        }
        if let aperture = exif[kCGImagePropertyExifFNumber] as? Double {
            parts.append("f/\(compactDecimal(aperture))")
        } else {
            parts.append("f/2.5")
        }
        if let exposure = exif[kCGImagePropertyExifExposureTime] as? Double, exposure > 0 {
            if exposure >= 1 {
                parts.append(String(format: "%.0fs", exposure))
            } else {
                parts.append(String(format: "1/%.0fs", 1.0 / exposure))
            }
        } else {
            parts.append("1/250s")
        }
        if let isoArray = exif[kCGImagePropertyExifISOSpeedRatings] as? [Any],
           let iso = isoArray.first as? NSNumber {
            parts.append("ISO \(iso.intValue)")
        } else {
            parts.append("ISO 50")
        }
        return parts.joined(separator: "  ")
    }

    private static func compactDecimal(_ value: Double) -> String {
        let formatted = String(format: "%.4f", value)
        return formatted
            .replacingOccurrences(of: #"0+$"#, with: "", options: .regularExpression)
            .replacingOccurrences(of: #"\.$"#, with: "", options: .regularExpression)
    }

    private enum WatermarkError: Error {
        case invalidImage
        case encodeFailed
    }
}
