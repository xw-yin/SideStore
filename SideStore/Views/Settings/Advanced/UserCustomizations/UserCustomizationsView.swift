//
//  UserCustomizationsView.swift
//  SideStore
//
//  Created by Magesh K on 8/2/26.
//  Copyright © 2026 SideStore. All rights reserved.
//

import SwiftUI
import AltStoreCore

private extension Color {
    static let settingsRowBackground = Color(uiColor: .secondarySystemGroupedBackground)
    static let settingsDivider = Color(uiColor: .separator)
}

struct UserCustomizationsView: View {
    @State private var customizeAppId: Bool = UserDefaults.standard.customizeAppId
    @State private var customizeAppExtensions: Bool = UserDefaults.standard.customizeAppExtensions
    @State private var isExportResignedAppEnabled: Bool = UserDefaults.standard.isExportResignedAppEnabled
    @State private var enableEMPforWireguard: Bool = UserDefaults.standard.enableEMPforWireguard
    @State private var skipNonCopyableFiles: Bool = UserDefaults.standard.skipNonCopyableBackupFiles

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                // Section 0: APPEARANCE & THEMES
                VStack(alignment: .leading, spacing: 8) {
                    Text("APPEARANCE & THEMES")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundColor(.secondary)
                        .padding(.horizontal, 16)
                    
                    NavigationLink(destination: ThemePickerView()) {
                        HStack {
                            Text("Theme Manager")
                                .font(.system(size: 17, weight: .bold))
                                .foregroundColor(.primary)
                            Spacer()
                            HStack(spacing: 6) {
                                Circle()
                                    .fill(Color(uiColor: ThemeManager.shared.primaryColor))
                                    .frame(width: 14, height: 14)
                                Image(systemName: "chevron.right")
                                    .font(.system(size: 14, weight: .semibold))
                                    .foregroundColor(Color.secondary.opacity(0.65))
                            }
                        }
                        .padding(.horizontal, 16)
                        .padding(.vertical, 14)
                    }
                    .background(Color.settingsRowBackground)
                    .cornerRadius(14)
                }

                // Section 1: APP & EXTENSIONS CUSTOMIZATION
                VStack(alignment: .leading, spacing: 8) {
                    Text("CUSTOMIZATION OPTIONS")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundColor(.secondary)
                        .padding(.horizontal, 16)
                    
                    VStack(spacing: 0) {
                        toggleRow(title: "Customize AppID", isOn: Binding(
                            get: { customizeAppId },
                            set: { newValue in
                                customizeAppId = newValue
                                UserDefaults.standard.customizeAppId = newValue
                            }
                        ))
                        
                        divider
                        
                        toggleRow(title: "Customize App Extensions", isOn: Binding(
                            get: { customizeAppExtensions },
                            set: { newValue in
                                customizeAppExtensions = newValue
                                UserDefaults.standard.customizeAppExtensions = newValue
                            }
                        ))
                        
                        divider
                        
                        toggleRow(title: "Export Resigned Apps", isOn: Binding(
                            get: { isExportResignedAppEnabled },
                            set: { newValue in
                                isExportResignedAppEnabled = newValue
                                UserDefaults.standard.isExportResignedAppEnabled = newValue
                            }
                        ))
                        
                        divider
                        
                        toggleRow(title: "EMProxy (WireGuard) Server", isOn: Binding(
                            get: { enableEMPforWireguard },
                            set: { newValue in
                                enableEMPforWireguard = newValue
                                UserDefaults.standard.enableEMPforWireguard = newValue
                            }
                        ))
                        
                        divider
                        
                        toggleRow(title: "Skip Uncopyable Backup Files", isOn: Binding(
                            get: { skipNonCopyableFiles },
                            set: { newValue in
                                skipNonCopyableFiles = newValue
                                UserDefaults.standard.skipNonCopyableBackupFiles = newValue
                            }
                        ))
                    }
                    .background(Color.settingsRowBackground)
                    .cornerRadius(14)
                }
            }
            .padding(.horizontal, 16)
            .padding(.top, 16)
            .padding(.bottom, 32)
        }
        .background(Color(uiColor: .systemGroupedBackground).ignoresSafeArea())
        .navigationTitle("User Customizations")
        .navigationBarTitleDisplayMode(.large)
    }

    private func toggleRow(title: String, isOn: Binding<Bool>) -> some View {
        HStack {
            Text(LocalizedStringKey(title))
                .font(.system(size: 17, weight: .bold))
                .foregroundColor(.primary)
                .fixedSize(horizontal: false, vertical: true)
            Spacer()
            Toggle("", isOn: isOn)
                .labelsHidden()
                .tint(.green)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .frame(minHeight: 50)
    }

    private var divider: some View {
        Rectangle()
            .fill(Color.settingsDivider)
            .frame(height: 0.5)
            .padding(.horizontal, 16)
    }
}
