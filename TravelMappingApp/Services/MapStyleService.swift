import SwiftUI

enum MapStyleService {
    enum LineStyle: String, CaseIterable, Identifiable {
        case solid = "Solid"
        case dashed = "Dashed"
        case dotted = "Dotted"
        case thick = "Thick"
        case thin = "Thin"

        var id: String { rawValue }

        var dashPattern: [CGFloat] {
            switch self {
            case .solid, .thick, .thin: return []
            case .dashed: return [8, 6]
            case .dotted: return [2, 4]
            }
        }

        var widthMultiplier: Double {
            switch self {
            case .thick: return 1.5
            case .thin: return 0.6
            default: return 1.0
            }
        }
    }

    static func parse(_ raw: String) -> LineStyle {
        LineStyle(rawValue: raw) ?? .solid
    }

    static func strokeStyle(for style: LineStyle, baseWidth: Double) -> StrokeStyle {
        StrokeStyle(
            lineWidth: baseWidth * style.widthMultiplier,
            lineCap: .round,
            dash: style.dashPattern
        )
    }
}
