//
//  ConnectionConfigView.swift
//  SideStore
//
//  Created by Magesh K on 02/03/26.
//  Copyright © 2026 SideStore. All rights reserved.
//

import SwiftUI
import Combine
import Minimuxer
import Darwin

private typealias SButton = SwiftUI.Button

enum ActiveState: String {
    case yes = "Yes"
    case no = "No"
}

struct ConnectionConfigView: View {
    @Environment(\.presentationMode) var presentationMode
    @ObservedObject private var config = ConnectionConfig.shared
    @State private var draftUseLocalVPN: Bool = ConnectionConfig.shared.useLocalVPN
    @State private var draftOverrideTunnelPeerIp: String = ConnectionConfig.shared.overrideTunnelPeerIp
    @State private var draftRemoteServerIp: String = ConnectionConfig.shared.remoteServerIp
    @State private var draftRemotePairingPortOverride: String = ""
    @State private var draftWireGuardServerHost: String = ConnectionConfig.shared.wireguardServerHost
    @State private var draftWireGuardServerPort: String = String(ConnectionConfig.shared.wireguardServerPort)
    @State private var alwaysShowWireGuardConfig: Bool = UserDefaults.standard.alwaysShowWireGuardConfig
    @State private var acceptIPv6ConnectionConfig: Bool = UserDefaults.standard.acceptIPv6ConnectionConfig
    @State private var showConfirmDialog = false
    @State private var validationError: String?
    @State private var showValidationErrorAlert = false

    var body: some View {
        ZStack {
            List {
                Section {
                    Toggle("Use Local VPN", isOn: $draftUseLocalVPN)
                }

                if draftUseLocalVPN {
                    Section(header: Text("Auto Discovered from network")) {
                        Group {
                            networkConfigRow(label: "Tunnel IP", text: Binding<String?>(get: { config.formattedTunnelIface }, set: { _ in }), editable: false)
                            networkConfigRow(label: "Device IP", text: Binding<String?>(get: { config.formattedTunnelPeer }, set: { _ in }), editable: false)
                            if minimuxer.gateway.pairingFileType == .rppairing {
                                networkConfigRow(label: "RemotePair Port", text: Binding<String?>(get: { String(remotePairingPortCache) }, set: { _ in }), editable: false)
                            }
                            if config.overrideTunnelPeerIp.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                                let hasDiscoveredPeer = config.tunnelPeerIp != nil && !config.tunnelPeerIp!.isEmpty
                                networkConfigRow(
                                    label: "Reachable",
                                    text: Binding<String?>(get: { hasDiscoveredPeer ? config.tunnelPeerActive.rawValue : "N/A" }, set: { _ in }),
                                    editable: false,
                                    textColor: hasDiscoveredPeer ? (config.tunnelPeerActive == .yes ? .green : .red) : .gray
                                )
                            }
                        }
                    }
                    
                    Section {
                        networkConfigRow(
                            label: "Device IP",
                            text: Binding<String?>(get: { draftOverrideTunnelPeerIp }, set: { draftOverrideTunnelPeerIp = $0 ?? "" }),
                            editable: true
                        )
                        if minimuxer.gateway.pairingFileType == .rppairing {
                            networkConfigRow(
                                label: "RemotePair Port",
                                text: Binding<String?>(get: { draftRemotePairingPortOverride }, set: { draftRemotePairingPortOverride = $0 ?? "" }),
                                editable: true,
                                isPort: true
                            )
                        }
                        if !config.overrideTunnelPeerIp.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                            networkConfigRow(
                                label: "Active",
                                text: Binding<String?>(get: { config.overrideTunnelPeerActive.rawValue }, set: { _ in }),
                                editable: false,
                                textColor: config.overrideTunnelPeerActive == .yes ? .green : .red
                            )
                        }
                    } header: {
                        Text("User Configuration")
                    } footer: {
                        HStack(alignment: .top, spacing: 0) {
                            Text("Note: ")
                            Text("'Device IP' and 'RemotePair Port' are optional and if specified should match exactly as in the target VPN's config or Leave empty to prefer auto-discovery/default port \(String(AppConstants.Minimuxer.remotePairingPort)).")
                        }
                    }
                } else {
                    Section {
                        networkConfigRow(
                            label: "Device IP",
                            text: Binding<String?>(get: { draftRemoteServerIp }, set: { draftRemoteServerIp = $0 ?? "" }),
                            editable: true
                        )
                        if minimuxer.gateway.pairingFileType == .rppairing {
                            networkConfigRow(
                                label: "RemotePair Port",
                                text: Binding<String?>(get: { draftRemotePairingPortOverride }, set: { draftRemotePairingPortOverride = $0 ?? "" }),
                                editable: true,
                                isPort: true
                            )
                        }
                        networkConfigRow(
                            label: "Reachable",
                            text: Binding<String?>(get: { config.remoteActive.rawValue }, set: { _ in }),
                            editable: false,
                            textColor: config.remoteActive == .yes ? .green : .red
                        )
                    } header: {
                        Text("Remote Endpoint")
                    } footer: {
                        HStack(alignment: .top, spacing: 0) {
                            Text("Note: ")
                            Text("'Device IP' is mandatory. 'RemotePair Port' is optional (prefers auto-discovery or default \(String(AppConstants.Minimuxer.remotePairingPort)).")
                        }
                    }
                }

                if UserDefaults.standard.enableEMPforWireguard || UserDefaults.standard.alwaysShowWireGuardConfig {
                    Section {
                        networkConfigRow(
                            label: "Bind Host / IP",
                            text: Binding<String?>(get: { draftWireGuardServerHost }, set: { draftWireGuardServerHost = $0 ?? "" }),
                            editable: true
                        )
                        networkConfigRow(
                            label: "Bind Port",
                            text: Binding<String?>(get: { draftWireGuardServerPort }, set: { draftWireGuardServerPort = $0 ?? "" }),
                            editable: true,
                            isPort: true
                        )
                    } header: {
                        Text("WireGuard Server Parameters")
                    } footer: {
                        Text("Configures the local UDP loopback host and port bound by EMProxy.")
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
                let portOverride = UserDefaults.standard.remotePairingPortOverride
                draftRemotePairingPortOverride = (portOverride > 0 && portOverride <= 65535) ? String(portOverride) : ""
                draftWireGuardServerHost = config.wireguardServerHost
                draftWireGuardServerPort = String(config.wireguardServerPort)
                alwaysShowWireGuardConfig = UserDefaults.standard.alwaysShowWireGuardConfig
                acceptIPv6ConnectionConfig = UserDefaults.standard.acceptIPv6ConnectionConfig
            }
            .alert(NSLocalizedString("Invalid Configuration", comment: ""), isPresented: $showValidationErrorAlert) {
                SwiftUI.Button(NSLocalizedString("OK", comment: ""), role: .cancel) {}
            } message: {
                Text(validationError ?? NSLocalizedString("Please check your configuration settings.", comment: ""))
            }
            .alert(NSLocalizedString("Changes saved", comment: ""), isPresented: $showConfirmDialog) {
                SwiftUI.Button(NSLocalizedString("OK", comment: ""), role: .cancel) {}
            } message: {
                Text(NSLocalizedString("Connection configuration has been updated.", comment: ""))
            }
        }
    }

    private func isIPv6Address(_ value: String) -> Bool {
        var clean = value.trimmingCharacters(in: .whitespacesAndNewlines)
        clean = clean.trimmingCharacters(in: CharacterSet(charactersIn: "[]"))
        if let scopeRange = clean.range(of: "%") {
            clean = String(clean[..<scopeRange.lowerBound])
        }
        var sin6 = sockaddr_in6()
        return inet_pton(AF_INET6, clean, &sin6.sin6_addr) == 1 || clean.contains(":")
    }

    private func isValidIPv6Address(_ value: String) -> Bool {
        var clean = value.trimmingCharacters(in: .whitespacesAndNewlines)
        clean = clean.trimmingCharacters(in: CharacterSet(charactersIn: "[]"))
        if let scopeRange = clean.range(of: "%") {
            clean = String(clean[..<scopeRange.lowerBound])
        }
        var sin6 = sockaddr_in6()
        return inet_pton(AF_INET6, clean, &sin6.sin6_addr) == 1
    }

    private func validateInputs() -> String? {
        let acceptIPv6 = UserDefaults.standard.acceptIPv6ConnectionConfig

        if draftUseLocalVPN {
            let overridePeer = draftOverrideTunnelPeerIp.trimmingCharacters(in: .whitespacesAndNewlines)
            if !overridePeer.isEmpty && isIPv6Address(overridePeer) {
                guard acceptIPv6 else {
                    return "IPv6 addresses are not supported for Device IP unless 'Accept IPv6 Config' is enabled in Developer Options."
                }
                guard isValidIPv6Address(overridePeer) else {
                    return "Invalid IPv6 address for Device IP."
                }
            }
        } else {
            let remoteIp = draftRemoteServerIp.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !remoteIp.isEmpty else {
                return "Device IP is mandatory for Remote Endpoint mode."
            }
            if isIPv6Address(remoteIp) {
                guard acceptIPv6 else {
                    return "IPv6 addresses are not supported for Device IP unless 'Accept IPv6 Config' is enabled in Developer Options."
                }
                guard isValidIPv6Address(remoteIp) else {
                    return "Invalid IPv6 address for Device IP."
                }
            }
        }
        if minimuxer.gateway.pairingFileType == .rppairing {
            let portStr = draftRemotePairingPortOverride.trimmingCharacters(in: .whitespacesAndNewlines)
            if !portStr.isEmpty {
                guard let port = UInt16(portStr), port > 0 else {
                    return "RemotePair Port must be a valid number between 1 and 65535 or left empty for auto-discovery."
                }
            }
        }
        if UserDefaults.standard.enableEMPforWireguard || UserDefaults.standard.alwaysShowWireGuardConfig {
            let host = draftWireGuardServerHost.trimmingCharacters(in: .whitespaces)
            guard !host.isEmpty else {
                return "Bind Host / IP cannot be empty."
            }
            if isIPv6Address(host) {
                guard acceptIPv6 else {
                    return "IPv6 addresses are not supported for Bind Host / IP unless 'Accept IPv6 Config' is enabled in Developer Options."
                }
                guard isValidIPv6Address(host) else {
                    return "Invalid IPv6 address for Bind Host / IP."
                }
            }
            guard let port = UInt16(draftWireGuardServerPort), port > 0 else {
                return "Bind Port must be a valid number between 1 and 65535."
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
        if minimuxer.gateway.pairingFileType == .rppairing {
            let portStr = draftRemotePairingPortOverride.trimmingCharacters(in: .whitespacesAndNewlines)
            if let port = Int(portStr), port > 0 && port <= 65535 {
                UserDefaults.standard.remotePairingPortOverride = port
            } else {
                UserDefaults.standard.remotePairingPortOverride = 0
            }
            syncMinimuxerBackendFromUserDefaults()
            try? await fetchUDID(forceLive: true)
        }
        await bindConnectionConfig()
        showConfirmDialog = true
    }
    
    private func dismiss() {
        presentationMode.wrappedValue.dismiss()
    }

    private func networkConfigRow(
        label: LocalizedStringKey,
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
                        proxy.wrappedValue = newValue.filter { "0123456789abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ.:%_".contains($0) }
                    }
                }
        }
    }
}
