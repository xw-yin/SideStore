//
//  ExperimentalFeaturesView.swift
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

struct ExperimentalFeaturesView: View {
    @State private var freeAcctAppIdDeletion: Bool = UserDefaults.standard.freeAcctAppIdDeletion
    @State private var isCellularRefreshEnabled: Bool = UserDefaults.standard.isCellularRefreshEnabled
    @State private var permissionCheckingDisabled: Bool = UserDefaults.standard.permissionCheckingDisabled
    @State private var appVerificationDisabled: Bool = UserDefaults.standard.appVerificationDisabled

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                // Section 1: STANDALONE FEATURES
                VStack(alignment: .leading, spacing: 8) {
                    Text("STANDALONE FEATURES")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundColor(.secondary)
                        .padding(.horizontal, 16)
                    
                    VStack(spacing: 0) {
                        if #available(iOS 26.0, *) {
                            NavigationLink(destination: WirelessPairView()) {
                                HStack {
                                    Text("Wireless Pairing")
                                        .font(.system(size: 17, weight: .bold))
                                        .foregroundColor(.primary)
                                    Spacer()
                                    Image(systemName: "chevron.right")
                                        .font(.system(size: 14, weight: .semibold))
                                        .foregroundColor(Color.secondary.opacity(0.65))
                                }
                                .padding(.horizontal, 16)
                                .frame(height: 50)
                            }
                            
                            divider
                        }
                        
                        NavigationLink(destination: CacheManagementView()) {
                            HStack {
                                Text("Cache Management")
                                    .font(.system(size: 17, weight: .bold))
                                    .foregroundColor(.primary)
                                Spacer()
                                Image(systemName: "chevron.right")
                                    .font(.system(size: 14, weight: .semibold))
                                    .foregroundColor(Color.secondary.opacity(0.65))
                            }
                            .padding(.horizontal, 16)
                            .frame(height: 50)
                        }
                    }
                    .background(Color.settingsRowBackground)
                    .cornerRadius(14)
                }
                
                // Section 2: FEATURE FLAGS
                VStack(alignment: .leading, spacing: 8) {
                    Text("FEATURE FLAGS")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundColor(.secondary)
                        .padding(.horizontal, 16)
                    
                    VStack(spacing: 0) {
                        toggleRow(title: "Free Account AppID Deletion", isOn: Binding(
                            get: { freeAcctAppIdDeletion },
                            set: { newValue in
                                freeAcctAppIdDeletion = newValue
                                UserDefaults.standard.freeAcctAppIdDeletion = newValue
                            }
                        ))
                        
                        divider
                        
                        toggleRow(title: "Cellular Refresh", isOn: Binding(
                            get: { isCellularRefreshEnabled },
                            set: { newValue in
                                isCellularRefreshEnabled = newValue
                                UserDefaults.standard.isCellularRefreshEnabled = newValue
                            }
                        ))
                        
                        divider
                        
                        toggleRow(title: "Permission Checks", isOn: Binding(
                            get: { !permissionCheckingDisabled },
                            set: { newValue in
                                permissionCheckingDisabled = !newValue
                                UserDefaults.standard.permissionCheckingDisabled = !newValue
                            }
                        ))
                        
                        divider
                        
                        toggleRow(title: "App Verification", isOn: Binding(
                            get: { !appVerificationDisabled },
                            set: { newValue in
                                appVerificationDisabled = !newValue
                                UserDefaults.standard.appVerificationDisabled = !newValue
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
        .navigationTitle("Experimental Features")
        .navigationBarTitleDisplayMode(.large)
    }

    private var divider: some View {
        Rectangle()
            .fill(Color.settingsDivider)
            .frame(height: 1)
            .padding(.leading, 16)
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
}
