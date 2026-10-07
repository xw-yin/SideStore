//
//  SettingsRowStyle.swift
//  SideStore
//
//  Small building blocks so SideStore's SwiftUI settings screens look like the rest of
//  Settings (uppercase section headers, rounded 50pt rows, dividers, settings background).
//

import SwiftUI

enum SettingsRowStyle {
    /// Card background: translucent white in dark mode, subtle gray in light mode.
    static let rowBackground = Color(uiColor: UIColor { traits in
        traits.userInterfaceStyle == .dark
            ? UIColor.white.withAlphaComponent(0.15)
            : UIColor.black.withAlphaComponent(0.05)
    })
    static let divider = Color(uiColor: UIColor { traits in
        traits.userInterfaceStyle == .dark
            ? UIColor.white.withAlphaComponent(0.15)
            : UIColor.black.withAlphaComponent(0.12)
    })
    /// Primary text: white in dark mode, near-black in light mode.
    static let primaryText = Color(uiColor: .label)
    /// Secondary text (adaptive).
    static let secondaryText = Color(uiColor: .secondaryLabel)
    /// Faint decorative elements like chevrons (adaptive).
    static let tertiaryText = Color(uiColor: .tertiaryLabel)
    static let background = Color(uiColor: .settingsBackground)
    /// Toast bubble: light translucent in dark mode, dark translucent in light mode.
    /// White text stays readable on both.
    static let toastBackground = Color(uiColor: UIColor { traits in
        traits.userInterfaceStyle == .dark
            ? UIColor.white.withAlphaComponent(0.18)
            : UIColor.black.withAlphaComponent(0.72)
    })
}

struct SettingsRowSection<Content: View>: View {
    let header: String
    var footer: String? = nil
    var footerColor: Color = SettingsRowStyle.secondaryText
    @ViewBuilder let content: () -> Content

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(header.uppercased())
                .font(.system(size: 13, weight: .semibold))
                .foregroundColor(SettingsRowStyle.secondaryText)
                .padding(.horizontal, 4)

            VStack(spacing: 0) {
                content()
            }
            .background(SettingsRowStyle.rowBackground)
            .cornerRadius(14)

            if let footer, !footer.isEmpty {
                Text(footer)
                    .font(.system(size: 13))
                    .foregroundColor(footerColor)
                    .padding(.horizontal, 4)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}

struct SettingsRowDivider: View {
    var body: some View {
        Divider()
            .background(SettingsRowStyle.divider)
            .padding(.horizontal, 16)
    }
}

/// A 50pt settings row: optional icon, bold title, optional trailing value, optional chevron/checkmark.
struct SettingsRow: View {
    let title: String
    var icon: String? = nil
    var value: String? = nil
    var showsChevron = false
    var isChecked = false
    var titleColor: Color = SettingsRowStyle.primaryText

    var body: some View {
        HStack(spacing: 12) {
            if let icon {
                Image(systemName: icon)
                    .font(.system(size: 17, weight: .semibold))
                    .foregroundColor(SettingsRowStyle.primaryText)
                    .frame(width: 24)
            }
            Text(title)
                .font(.system(size: 17, weight: .bold))
                .foregroundColor(titleColor)
                .lineLimit(1)
                .minimumScaleFactor(0.8)
            Spacer(minLength: 8)
            if let value {
                Text(value)
                    .font(.system(size: 15))
                    .foregroundColor(SettingsRowStyle.secondaryText)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            if isChecked {
                Image(systemName: "checkmark")
                    .font(.system(size: 15, weight: .bold))
                    .foregroundColor(.accentColor)
            }
            if showsChevron {
                Image(systemName: "chevron.right")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundColor(SettingsRowStyle.tertiaryText)
            }
        }
        .padding(.horizontal, 16)
        .frame(minHeight: 50)
        .contentShape(Rectangle())
    }
}
