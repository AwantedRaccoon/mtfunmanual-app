import Foundation
import UIKit
import CoreText

enum VisitSummaryPDFRenderer {
    static let pageSize = CGSize(width: 595.2, height: 841.8)

    static func render(_ snapshot: VisitSummarySnapshot) throws -> Data {
        let bounds = CGRect(origin: .zero, size: pageSize)
        let renderer = UIGraphicsPDFRenderer(bounds: bounds)
        let projection = VisitSummaryDisclosureProjection(
            snapshot: snapshot
        )
        let data = renderer.pdfData { context in
            var writer = PDFWriter(context: context, bounds: bounds)
            writer.beginPage()
            writer.heading("就诊摘要")
            for row in projection.metadataRows {
                writer.body(row)
            }
            writer.rule()

            for section in projection.sections
                where !section.rows.isEmpty {
                writer.section(section.title)
                for row in section.rows {
                    writer.bullet(row)
                }
            }

            writer.rule()
            writer.disclaimer(VisitSummarySnapshot.disclaimer)
            writer.note("导出文件离开 App 后，不再受 App Lock 保护。")
        }
        guard data.count > 32,
              String(data: data.prefix(5), encoding: .ascii) == "%PDF-" else {
            throw VisitSummaryFailure.corruptedData
        }
        return data
    }

}

private struct PDFWriter {
    private let context: UIGraphicsPDFRendererContext
    private let bounds: CGRect
    private let margin: CGFloat = 42
    private let bottomMargin: CGFloat = 44
    private var cursorY: CGFloat = 42

    init(context: UIGraphicsPDFRendererContext, bounds: CGRect) {
        self.context = context
        self.bounds = bounds
    }

    mutating func beginPage() {
        context.beginPage()
        cursorY = margin
    }

    mutating func heading(_ text: String) {
        draw(
            text,
            font: .systemFont(ofSize: 25, weight: .bold),
            color: UIColor(red: 0.09, green: 0.18, blue: 0.29, alpha: 1),
            spacingAfter: 12
        )
    }

    mutating func meta(_ label: String, _ value: String) {
        draw(
            "\(label)：\(value)",
            font: .systemFont(ofSize: 9.5, weight: .medium),
            color: UIColor(red: 0.28, green: 0.35, blue: 0.40, alpha: 1),
            spacingAfter: 3
        )
    }

    mutating func section(_ text: String) {
        ensureSpace(35)
        cursorY += 9
        draw(
            text,
            font: .systemFont(ofSize: 14, weight: .bold),
            color: UIColor(red: 0.09, green: 0.18, blue: 0.29, alpha: 1),
            spacingAfter: 5
        )
    }

    mutating func body(_ text: String) {
        draw(
            text,
            font: .systemFont(ofSize: 10.5),
            color: UIColor(red: 0.06, green: 0.13, blue: 0.21, alpha: 1),
            spacingAfter: 4
        )
    }

    mutating func bullet(_ text: String) {
        draw(
            "•  " + text,
            font: .systemFont(ofSize: 10.5),
            color: UIColor(red: 0.06, green: 0.13, blue: 0.21, alpha: 1),
            indent: 10,
            spacingAfter: 4
        )
    }

    mutating func note(_ text: String) {
        draw(
            text,
            font: .systemFont(ofSize: 9),
            color: UIColor(red: 0.28, green: 0.35, blue: 0.40, alpha: 1),
            indent: 10,
            spacingAfter: 4
        )
    }

    mutating func disclaimer(_ text: String) {
        draw(
            text,
            font: .systemFont(ofSize: 10.5, weight: .bold),
            color: UIColor(red: 0.55, green: 0.16, blue: 0.13, alpha: 1),
            spacingAfter: 5
        )
    }

    mutating func rule() {
        ensureSpace(18)
        cursorY += 9
        let path = UIBezierPath()
        path.move(to: CGPoint(x: margin, y: cursorY))
        path.addLine(to: CGPoint(x: bounds.width - margin, y: cursorY))
        UIColor(red: 0.09, green: 0.18, blue: 0.29, alpha: 1).setStroke()
        path.lineWidth = 0.8
        path.stroke()
        cursorY += 9
    }

    private mutating func ensureSpace(_ height: CGFloat) {
        if cursorY + height > bounds.height - bottomMargin {
            beginPage()
        }
    }

    private mutating func draw(
        _ text: String,
        font: UIFont,
        color: UIColor,
        indent: CGFloat = 0,
        spacingAfter: CGFloat
    ) {
        let paragraph = NSMutableParagraphStyle()
        paragraph.lineBreakMode = .byWordWrapping
        paragraph.lineSpacing = 2
        let attributes: [NSAttributedString.Key: Any] = [
            .font: font,
            .foregroundColor: color,
            .paragraphStyle: paragraph
        ]
        let width = bounds.width - margin * 2 - indent
        let attributed = NSAttributedString(string: text, attributes: attributes)
        let framesetter = CTFramesetterCreateWithAttributedString(
            attributed
        )
        var location = 0
        while location < attributed.length {
            let minimumLineHeight = ceil(font.lineHeight + paragraph.lineSpacing)
            var available = bounds.height - bottomMargin - cursorY
            if available < minimumLineHeight {
                beginPage()
                available = bounds.height - bottomMargin - cursorY
            }
            let frame = CGRect(
                x: margin + indent,
                y: cursorY,
                width: width,
                height: available
            )
            let coreTextRect = CGRect(
                x: frame.minX,
                y: bounds.height - frame.maxY,
                width: frame.width,
                height: frame.height
            )
            let path = CGPath(rect: coreTextRect, transform: nil)
            let textFrame = CTFramesetterCreateFrame(
                framesetter,
                CFRange(
                    location: location,
                    length: attributed.length - location
                ),
                path,
                nil
            )
            let visible = CTFrameGetVisibleStringRange(
                textFrame
            )
            guard visible.length > 0 else {
                beginPage()
                continue
            }
            let cg = context.cgContext
            cg.saveGState()
            cg.textMatrix = .identity
            cg.translateBy(x: 0, y: bounds.height)
            cg.scaleBy(x: 1, y: -1)
            CTFrameDraw(textFrame, cg)
            cg.restoreGState()
            let measured = CTFramesetterSuggestFrameSizeWithConstraints(
                framesetter,
                CFRange(
                    location: location,
                    length: visible.length
                ),
                nil,
                CGSize(
                    width: width,
                    height: .greatestFiniteMagnitude
                ),
                nil
            )
            location += visible.length
            cursorY += ceil(measured.height) + spacingAfter
            if location < attributed.length {
                beginPage()
            }
        }
    }
}
