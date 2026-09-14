//
//  ConnectionConfigView.swift
//  SideStore
//
//  Created by Magesh K on 02/03/26.
//  Copyright © 2026 SideStore. All rights reserved.
//

import SwiftUI
import Combine

private typealias SButton = SwiftUI.Button

enum ActiveState: String {
    case yes = "Yes"
    case no = "No"

    var localized: String {
        switch self {
        case .yes: return NSLocalizedString("Yes", comment: "")
        case .no: return NSLocalizedString("No", comment: "")
        }
    }
}

struct ConnectionConfigView: View {
    @Environment(\.presentationMode) var presentationMode
    @ObservedObject private var config = ConnectionConfig.shared
    @State private var draftUseLocalVPN: Bool = ConnectionConfig.shared.useLocalVPN
    @State private var draftOverrideTunnelPeerIp: String = ConnectionConfig.shared.overrideTunnelPeerIp
    @State private var draftRemoteServerIp: String = ConnectionConfig.shared.remoteServerIp
    @State private var draftWireGuardServerHost: String = ConnectionConfig.shared.wireguardServerHost
    @State private var draftWireGuardServerPort: String = String(ConnectionConfig.shared.wireguardServerPort)
    @State private var alwaysShowWireGuardConfig: Bool = UserDefaults.standard.alwaysShowWireGuardConfig
    @State private var showConfirmDialog = false
    @State private var validationError: String?
    @State private var showValidationErrorAlert = false

    var body: some View {
        List {
            Section {
                Toggle(NSLocalizedString("Use Local VPN", comment: ""), isOn: $draftUseLocalVPN)
            }

            if draftUseLocalVPN {
                Section(header: Text(NSLocalizedString("Auto Discovered from network", comment: ""))) {
                    Group {
                        networkConfigRow(label: NSLocalizedString("Tunnel IP", comment: ""), text: Binding<String?>(get: { config.formattedTunnelIface }, set: { _ in }), editable: false)
                        networkConfigRow(label: NSLocalizedString("Device IP", comment: ""), text: Binding<String?>(get: { config.formattedTunnelPeer }, set: { _ in }), editable: false)
                        if config.overrideTunnelPeerIp.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                            let hasDiscoveredPeer = config.tunnelPeerIp != nil && !config.tunnelPeerIp!.isEmpty
                            networkConfigRow(
                                label: NSLocalizedString("Reachable", comment: ""),
                                text: Binding<String?>(get: { hasDiscoveredPeer ? config.tunnelPeerActive.localized : "N/A" }, set: { _ in }),
                                editable: false,
                                textColor: hasDiscoveredPeer ? (config.tunnelPeerActive == .yes ? .green : .red) : .gray
                            )
                        }
                    }
                }
                
                Section {
                    networkConfigRow(
                        label: NSLocalizedString("Device IP", comment: ""),
                        text: Binding<String?>(get: { draftOverrideTunnelPeerIp }, set: { draftOverrideTunnelPeerIp = $0 ?? "" }),
                        editable: true
                    )
                    if !config.overrideTunnelPeerIp.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                        networkConfigRow(
                            label: NSLocalizedString("Active", comment: ""),
                            text: Binding<String?>(get: { config.overrideTunnelPeerActive.localized }, set: { _ in }),
                            editable: false,
                            textColor: config.overrideTunnelPeerActive == .yes ? .green : .red
                        )
                    }
                } header: {
                    Text(NSLocalizedString("User Configuration", comment: ""))
                } footer: {
                    HStack(alignment: .top, spacing: 0) {
                        Text(NSLocalizedString("Note: ", comment: ""))
                        Text(NSLocalizedString("'Device IP' is optional and if specified should match exactly as in the target VPN's config or Leave empty to prefer auto-discovery.", comment: ""))
                    }
                }
            } else {
                Section {
                    networkConfigRow(
                        label: NSLocalizedString("Device IP / Endpoint", comment: ""),
                        text: Binding<String?>(get: { draftRemoteServerIp }, set: { draftRemoteServerIp = $0 ?? "" }),
                        editable: true
                    )
                    networkConfigRow(
                        label: NSLocalizedString("Reachable", comment: ""),
                        text: Binding<String?>(get: { config.remoteActive.localized }, set: { _ in }),
                        editable: false,
                        textColor: config.remoteActive == .yes ? .green : .red
                    )
                } header: {
                    Text(NSLocalizedString("Remote Endpoint", comment: ""))
                } footer: {
                    HStack(alignment: .top, spacing: 0) {
                        Text(NSLocalizedString("Note: ", comment: ""))
                        Text(NSLocalizedString("'Device IP / Endpoint' is mandatory and should match the remote server's address", comment: ""))
                    }
                }
            }

            if UserDefaults.standard.enableEMPforWireguard || UserDefaults.standard.alwaysShowWireGuardConfig {
                Section {
                    networkConfigRow(
                        label: NSLocalizedString("Bind Host / IP", comment: ""),
                        text: Binding<String?>(get: { draftWireGuardServerHost }, set: { draftWireGuardServerHost = $0 ?? "" }),
                        editable: true
                    )
                    networkConfigRow(
                        label: NSLocalizedString("Bind Port", comment: ""),
                        text: Binding<String?>(get: { draftWireGuardServerPort }, set: { draftWireGuardServerPort = $0 ?? "" }),
                        editable: true,
                        isPort: true
                    )
                } header: {
                    Text(NSLocalizedString("WireGuard Server Parameters", comment: ""))
                } footer: {
                    Text(NSLocalizedString("Configures the local UDP loopback host and port bound by EMProxy.", comment: ""))
                }
            }
        }
        .navigationTitle(NSLocalizedString("Connection Config", comment: ""))
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                SButton(NSLocalizedString("Confirm", comment: "")) {
                    Task { await commitChanges() }
                }
            }
        }
        .onAppear {
            draftUseLocalVPN = config.useLocalVPN
            draftOverrideTunnelPeerIp = config.overrideTunnelPeerIp
            draftRemoteServerIp = config.remoteServerIp
            draftWireGuardServerHost = config.wireguardServerHost
            draftWireGuardServerPort = String(config.wireguardServerPort)
            alwaysShowWireGuardConfig = UserDefaults.standard.alwaysShowWireGuardConfig
        }
        .alert(NSLocalizedString("Invalid Configuration", comment: ""), isPresented: $showValidationErrorAlert) {
            SwiftUI.Button(NSLocalizedString("OK", comment: ""), role: .cancel) {}
        } message: {
            Text(validationError ?? NSLocalizedString("Please check your configuration settings.", comment: ""))
        }
        .alert(NSLocalizedString("Configuration Saved", comment: ""), isPresented: $showConfirmDialog) {
            SwiftUI.Button(NSLocalizedString("OK", comment: ""), role: .cancel) {}
        }
    }

    private func validateInputs() -> String? {
        if !draftUseLocalVPN {
            let remoteIp = draftRemoteServerIp.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !remoteIp.isEmpty else {
                return NSLocalizedString("Device IP / Endpoint is mandatory for Remote Endpoint mode.", comment: "")
            }
        }
        if UserDefaults.standard.enableEMPforWireguard || UserDefaults.standard.alwaysShowWireGuardConfig {
            let host = draftWireGuardServerHost.trimmingCharacters(in: .whitespaces)
            guard !host.isEmpty else {
                return NSLocalizedString("Bind Host / IP cannot be empty.", comment: "")
            }
            guard let port = UInt16(draftWireGuardServerPort), port > 0 else {
                return NSLocalizedString("Bind Port must be a valid number between 1 and 65535.", comment: "")
            }
        }
        return nil
    }

    private func commitChanges() async {
        if let errorMsg = validateInputs() {
            self.validationError = errorMsg
            self.showValidationErrorAlert = true
            return
        }
        config.useLocalVPN = draftUseLocalVPN
        config.overrideTunnelPeerIp = draftOverrideTunnelPeerIp
        config.remoteServerIp = draftRemoteServerIp
        config.wireguardServerHost = draftWireGuardServerHost.trimmingCharacters(in: .whitespaces)
        config.wireguardServerPort = UInt16(draftWireGuardServerPort)!
        await bindConnectionConfig()
        showConfirmDialog = true
    }
    
    private func dismiss() {
        presentationMode.wrappedValue.dismiss()
    }

    private func networkConfigRow(
        label: String,
        text: Binding<String?>,
        editable: Bool,
        textColor: Color? = nil,
        isPort: Bool = false
    ) -> some View {

        let proxy = Binding<String>(
            get: { text.wrappedValue ?? "N/A" },
            set: { text.wrappedValue = $0.isEmpty || $0 == "N/A" ? nil : $0 }
        )

        return HStack {
            Text(label)
                .foregroundColor(editable ? .primary : .gray)
            Spacer()
            TextField(label, text: proxy)
                .multilineTextAlignment(.trailing)
                .foregroundColor(textColor ?? (editable ? .secondary : .gray))
                .disabled(!editable)
                .keyboardType(isPort ? .numberPad : .numbersAndPunctuation)
                .onChange(of: proxy.wrappedValue) { newValue in
                    guard editable else { return }
                    if isPort {
                        let digits = newValue.filter { "0123456789".contains($0) }
                        if let val = UInt32(digits), val <= 65535 {
                            proxy.wrappedValue = digits
                        } else if digits.isEmpty {
                            proxy.wrappedValue = ""
                        } else {
                            proxy.wrappedValue = String(digits.prefix(5).filter { "0123456789".contains($0) })
                        }
                    } else {
                        proxy.wrappedValue = newValue.filter { "0123456789.".contains($0) }
                    }
                }
        }
    }
}
