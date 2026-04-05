import SwiftUI

enum ThemeService {
    static let availableColors: [(name: String, color: Color)] = [
        ("Blue", .blue),
        ("Red", .red),
        ("Green", .green),
        ("Purple", .purple),
        ("Orange", .orange),
        ("Teal", .teal),
        ("Indigo", .indigo),
        ("Pink", .pink),
    ]

    static func color(named name: String) -> Color {
        availableColors.first { $0.name == name }?.color ?? .blue
    }
}
