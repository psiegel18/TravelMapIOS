import SwiftUI
import UIKit

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

// MARK: - Design System (iOS Design Audit)
// Semantic palette + shared components from the design audit. Embedded here rather
// than a new file per project convention (pbxproj edits are unreliable).

extension Color {
    /// Hex initializer for audit-spec colors, e.g. Color(tmHex: 0x2F6BF0).
    init(tmHex hex: UInt32, opacity: Double = 1) {
        self.init(
            .sRGB,
            red: Double((hex >> 16) & 0xFF) / 255,
            green: Double((hex >> 8) & 0xFF) / 255,
            blue: Double(hex & 0xFF) / 255,
            opacity: opacity
        )
    }

    /// Light/dark adaptive color.
    init(tmLight light: UInt32, dark: UInt32) {
        self.init(uiColor: UIColor { traits in
            let hex = traits.userInterfaceStyle == .dark ? dark : light
            return UIColor(
                red: CGFloat((hex >> 16) & 0xFF) / 255,
                green: CGFloat((hex >> 8) & 0xFF) / 255,
                blue: CGFloat(hex & 0xFF) / 255,
                alpha: 1
            )
        })
    }
}

/// Semantic design tokens. Light values from audit §0.2, dark from §10.
enum TMDesign {
    // MARK: Core palette
    /// Trailblazer Blue — primary accent / tint.
    static let accent = Color(tmLight: 0x2F6BF0, dark: 0x5B8CFF)
    /// Clinched Green — driven / complete.
    static let clinched = Color(tmLight: 0x2FB170, dark: 0x4FD69C)
    /// Frontier Amber — new / remaining.
    static let frontier = Color(tmLight: 0xE8912D, dark: 0xF6B45A)
    /// Rail red — rail & transit, destructive/stop, recording.
    static let rail = Color(tmLight: 0xD6453E, dark: 0xF08079)
    /// Gold — favorites, rank #1.
    static let gold = Color(tmHex: 0xF2C438)

    // MARK: Tinted chip pairs (bg / fg)
    static let blueChipBG = Color(tmLight: 0xEAF1FE, dark: 0x12294D)
    static let blueChipFG = Color(tmLight: 0x2F6BF0, dark: 0x78A6FF)
    static let greenChipBG = Color(tmLight: 0xE7F4EE, dark: 0x143327)
    static let greenChipFG = Color(tmLight: 0x1F8F5B, dark: 0x4FD69C)
    static let amberChipBG = Color(tmLight: 0xFBEFDD, dark: 0x3A2A12)
    static let amberChipFG = Color(tmLight: 0xB4700F, dark: 0xF6B45A)
    static let redChipBG = Color(tmLight: 0xFDEBEB, dark: 0x3D1A19)
    static let redChipFG = Color(tmLight: 0xD6453E, dark: 0xF08079)
    static let purpleChipBG = Color(tmLight: 0xF2ECFD, dark: 0x2A2140)
    static let purpleChipFG = Color(tmLight: 0x8B5CF6, dark: 0xB49AFF)
    static let goldChipBG = Color(tmLight: 0xFDF2D6, dark: 0x3A2F14)
    static let goldChipFG = Color(tmLight: 0xB47F14, dark: 0xF2C438)
    static let neutralChipBG = Color(tmLight: 0xE9EDF5, dark: 0x26262A)
    static let neutralChipFG = Color(tmLight: 0x586074, dark: 0xA0A0AA)

    // MARK: Surfaces & text
    static let cardBG = Color(tmLight: 0xFFFFFF, dark: 0x1C1C1E)
    static let secondarySurface = Color(tmLight: 0xF2F2F7, dark: 0x26262A)
    static let hairline = Color(tmLight: 0xF0F0F4, dark: 0x2A2A2C)
    static let progressTrack = Color(tmLight: 0xEEF0F4, dark: 0x2A2A2E)
    static let ringTrack = Color(tmLight: 0xE7E7EC, dark: 0x2A2A2E)
    static let secondaryText = Color(tmLight: 0x5C5C63, dark: 0xA0A0AA)
    static let tertiaryText = Color(tmLight: 0x8A8A90, dark: 0x8A8A90)
    static let chevron = Color(tmLight: 0xC4C4C9, dark: 0x4A4A50)

    /// Section headers: 13pt/700 uppercase tracked.
    static func sectionHeader(_ text: String) -> some View {
        Text(text.uppercased())
            .font(.system(size: 13, weight: .bold))
            .kerning(0.5)
            .foregroundStyle(tertiaryText)
    }
}

/// The audit's shared progress motif: conic completion ring with centered percent.
/// Used by the Statistics hero, Region detail, and the share card.
struct TMCompletionRing: View {
    let fraction: Double          // 0...1
    var diameter: CGFloat = 112
    var lineWidth: CGFloat = 14
    var fill: Color = TMDesign.accent
    var track: Color = TMDesign.ringTrack
    var caption: String = "clinched"
    var percentFont: CGFloat = 26

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var animatedFraction: Double = 0

    var body: some View {
        ZStack {
            Circle()
                .stroke(track, lineWidth: lineWidth)
            Circle()
                .trim(from: 0, to: animatedFraction)
                .stroke(fill, style: StrokeStyle(lineWidth: lineWidth, lineCap: .round))
                .rotationEffect(.degrees(-90))
            VStack(spacing: 1) {
                Text("\(Int((fraction * 100).rounded()))%")
                    .font(.system(size: percentFont, weight: .heavy))
                    .monospacedDigit()
                if !caption.isEmpty {
                    Text(caption)
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(TMDesign.tertiaryText)
                }
            }
        }
        .frame(width: diameter, height: diameter)
        .onAppear {
            if reduceMotion {
                animatedFraction = fraction
            } else {
                withAnimation(.easeOut(duration: 0.9)) { animatedFraction = fraction }
            }
        }
        .onChange(of: fraction) { _, newValue in
            if reduceMotion {
                animatedFraction = newValue
            } else {
                withAnimation(.easeOut(duration: 0.5)) { animatedFraction = newValue }
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(Int((fraction * 100).rounded())) percent \(caption)")
    }
}

/// Rounded-square monogram avatar (audit §0.5).
struct TMMonogramAvatar: View {
    let name: String
    var size: CGFloat = 40
    var isFavorite: Bool = false
    var background: Color?
    var foreground: Color?

    private var initials: String {
        String(name.trimmingCharacters(in: .whitespaces).prefix(2)).uppercased()
    }

    var body: some View {
        Text(initials)
            .font(.system(size: size * 0.42, weight: .heavy))
            .foregroundStyle(foreground ?? (isFavorite ? TMDesign.goldChipFG : TMDesign.neutralChipFG))
            .frame(width: size, height: size)
            .background(
                background ?? (isFavorite ? TMDesign.goldChipBG : TMDesign.neutralChipBG),
                in: RoundedRectangle(cornerRadius: size * 0.3, style: .continuous)
            )
            .accessibilityHidden(true)
    }
}

/// Small labeled chip — icon + text so meaning never rides on color alone (audit §0.4).
struct TMChip: View {
    let text: String
    var icon: String?
    var bg: Color = TMDesign.blueChipBG
    var fg: Color = TMDesign.blueChipFG
    var fontSize: CGFloat = 12

    var body: some View {
        HStack(spacing: 4) {
            if let icon {
                Image(systemName: icon)
                    .font(.system(size: fontSize - 1, weight: .semibold))
            }
            Text(text)
                .font(.system(size: fontSize, weight: .semibold))
                .monospacedDigit()
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 3)
        .background(bg, in: RoundedRectangle(cornerRadius: 7, style: .continuous))
        .foregroundStyle(fg)
    }
}

/// Pulsing recording dot (1.4s ease-in-out; static under Reduce Motion).
struct TMPulsingDot: View {
    var color: Color = .white
    var size: CGFloat = 8

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var dimmed = false

    var body: some View {
        Circle()
            .fill(color)
            .frame(width: size, height: size)
            .opacity(dimmed ? 0.3 : 1)
            .onAppear {
                guard !reduceMotion else { return }
                withAnimation(.easeInOut(duration: 0.7).repeatForever(autoreverses: true)) {
                    dimmed = true
                }
            }
            .accessibilityHidden(true)
    }
}

/// Skeleton placeholder row for streaming loads (audit §11).
struct TMSkeletonRow: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var pulsing = false

    var body: some View {
        HStack(spacing: 12) {
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(Color(tmLight: 0xECECF1, dark: 0x26262A))
                .frame(width: 34, height: 34)
            VStack(alignment: .leading, spacing: 7) {
                RoundedRectangle(cornerRadius: 4)
                    .fill(Color(tmLight: 0xECECF1, dark: 0x26262A))
                    .frame(height: 12)
                    .frame(maxWidth: .infinity)
                    .scaleEffect(x: 0.6, anchor: .leading)
                RoundedRectangle(cornerRadius: 4)
                    .fill(Color(tmLight: 0xF0F0F4, dark: 0x222226))
                    .frame(height: 9)
                    .frame(maxWidth: .infinity)
                    .scaleEffect(x: 0.4, anchor: .leading)
            }
        }
        .padding(.vertical, 8)
        .opacity(pulsing ? 0.55 : 1)
        .onAppear {
            guard !reduceMotion else { return }
            withAnimation(.easeInOut(duration: 0.7).repeatForever(autoreverses: true)) {
                pulsing = true
            }
        }
        .accessibilityHidden(true)
    }
}
