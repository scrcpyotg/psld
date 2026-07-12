import Foundation
import UIKit

@MainActor
enum PDFReportGenerator {
    static func makeReport(
        record: SavedScanRecord,
        document: FaceScanDocument
    ) -> URL? {
        let page = CGRect(x: 0, y: 0, width: 595, height: 842)
        let renderer = UIGraphicsPDFRenderer(bounds: page)
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd-HHmm"
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("PSL-Report-\(formatter.string(from: record.savedAt)).pdf")

        do {
            try renderer.writePDF(to: url) { context in
                var y: CGFloat = 42
                context.beginPage()
                draw("PSL Scanner — отчёт анализа", x: 42, y: y, size: 24, weight: .bold)
                y += 38
                draw(record.savedAt.formatted(date: .long, time: .shortened), x: 42, y: y, size: 11, color: .darkGray)
                y += 35

                draw(String(format: "PSL estimate: %.2f", record.score), x: 42, y: y, size: 34, weight: .bold)
                y += 42
                draw("Категория: \(record.category)", x: 42, y: y, size: 16, weight: .semibold)
                y += 24
                draw(String(format: "Диапазон: %.2f–%.2f", record.scoreRangeLow, record.scoreRangeHigh), x: 42, y: y, size: 12)
                y += 20
                draw("Качество: \(record.quality)/100   Повторяемость: \(record.repeatabilityScore)%", x: 42, y: y, size: 12)
                y += 34

                draw("3D-метрики", x: 42, y: y, size: 18, weight: .bold)
                y += 26
                for metric in record.featureMetrics.prefix(12) {
                    draw(metric.title, x: 50, y: y, size: 11)
                    draw(String(format: "%.0f/100 · %.2f %@ · C %d%%", metric.score, metric.rawValue, metric.rawUnit, metric.confidence), x: 300, y: y, size: 10, color: .darkGray)
                    y += 19
                    if y > 760 {
                        context.beginPage()
                        y = 42
                    }
                }

                y += 16
                draw("Региональная симметрия", x: 42, y: y, size: 18, weight: .bold)
                y += 26
                for region in record.regionalSymmetry {
                    draw(region.title, x: 50, y: y, size: 11)
                    draw(String(format: "%.2f мм ошибки · %.0f/100", region.errorMM, region.score), x: 320, y: y, size: 10, color: .darkGray)
                    y += 19
                }

                y += 20
                draw("Технические данные", x: 42, y: y, size: 18, weight: .bold)
                y += 26
                draw("Вершины: \(document.vertexCount)   Треугольники: \(document.triangleCount)", x: 50, y: y, size: 11)
                y += 18
                draw(String(format: "Depth Fusion: %@ · покрытие %.1f%%", document.metrics.depthFusion.applied ? "ACTIVE" : "FALLBACK", document.metrics.depthFusion.coveragePercent), x: 50, y: y, size: 11)
                y += 30

                let note = "Экспериментальный анализ наружной поверхности лица. Это не медицинское заключение, не изображение костей и не объективная оценка личности. Сравнивай только сканы сопоставимого качества."
                drawWrapped(note, rect: CGRect(x: 42, y: y, width: 510, height: 80), size: 10, color: .darkGray)
            }
            return url
        } catch {
            return nil
        }
    }

    private static func draw(
        _ text: String,
        x: CGFloat,
        y: CGFloat,
        size: CGFloat,
        weight: UIFont.Weight = .regular,
        color: UIColor = .black
    ) {
        let attributes: [NSAttributedString.Key: Any] = [
            .font: UIFont.systemFont(ofSize: size, weight: weight),
            .foregroundColor: color
        ]
        text.draw(at: CGPoint(x: x, y: y), withAttributes: attributes)
    }

    private static func drawWrapped(
        _ text: String,
        rect: CGRect,
        size: CGFloat,
        color: UIColor
    ) {
        let paragraph = NSMutableParagraphStyle()
        paragraph.lineBreakMode = .byWordWrapping
        let attributes: [NSAttributedString.Key: Any] = [
            .font: UIFont.systemFont(ofSize: size),
            .foregroundColor: color,
            .paragraphStyle: paragraph
        ]
        text.draw(in: rect, withAttributes: attributes)
    }
}
