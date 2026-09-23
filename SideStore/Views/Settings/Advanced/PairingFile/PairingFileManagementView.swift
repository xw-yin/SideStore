//
//  PairingFileManagementView.swift
//  SideStore
//
//  Created by Magesh K on 19/09/26.
//  Copyright © 2026 SideStore. All rights reserved.
//

import SwiftUI
import UniformTypeIdentifiers
import MinimuxerCommon

struct PairingFileManagementView: View {
    @StateObject private var viewModel = PairingFileManagementViewModel()

    var body: some View {
        List {
            activeProtocolSection

            ForEach(Array(viewModel.supportedProtocols.enumerated()), id: \.element.rawValue) { index, proto in
                pairingFileSection(for: proto, showHeader: index == 0)
            }

            pairingMethodsSection
            managementSection
        }
        #if !os(tvOS)
        .listStyle(InsetGroupedListStyle())
        #else
        .listStyle(GroupedListStyle())
        #endif
        .navigationTitle("Pairing File Management")
        #if !os(tvOS)
        .navigationBarTitleDisplayMode(.inline)
        #endif
        .toolbar {
            ToolbarItem(placement: .navigationBarTrailing) {
                SwiftUI.Button {
                    viewModel.toggleGlobalHide()
                } label: {
                    Image(systemName: viewModel.isGlobalHideActive ? "eye.slash" : "eye")
                }
                .accessibilityLabel("Toggle Sensitive Information")
            }
        }
        .onAppear {
            viewModel.refresh()
        }
        #if !os(tvOS)
        .fileImporter(
            isPresented: $viewModel.showFileImporter,
            allowedContentTypes: viewModel.allowedPairingTypes
        ) { result in
            viewModel.handleImportResult(result)
        }
        #endif
        .alert(item: $viewModel.activeAlert) { alert in
            switch alert {
            case .deleteConfirmation(let proto):
                return Alert(
                    title: Text("Delete Pairing File?"),
                    message: Text(LocalizedStringKey("Are you sure you want to delete this pairing file? This will remove the pairing credentials for **\(proto.rawValue)**.")),
                    primaryButton: .destructive(Text("Delete")) {
                        viewModel.deletePairingFile(for: proto)
                    },
                    secondaryButton: .cancel()
                )
            case .resetConfirmation:
                return Alert(
                    title: Text("Reset Pairing Files?"),
                    message: Text(LocalizedStringKey("This will delete all stored pairing files (both **Lockdown** and **Remote Pairing**). You will need to re-pair or re-import a pairing file and restart SideStore.")),
                    primaryButton: .destructive(Text("Delete and Reset")) {
                        viewModel.resetAllPairingFiles()
                    },
                    secondaryButton: .cancel()
                )
            case .resetCompleted:
                return Alert(
                    title: Text("Pairing Files Reset"),
                    message: Text("All pairing files have been reset. Please restart SideStore."),
                    dismissButton: .default(Text("OK"))
                )
            case .importError(let msg):
                return Alert(
                    title: Text("Import Error"),
                    message: Text(LocalizedStringKey(msg)),
                    dismissButton: .default(Text("OK"))
                )
            }
        }
    }

    private var activeProtocolSection: some View {
        Section(header: Text("ACTIVE PROTOCOL")) {
            HStack {
                Text("Active Protocol")
                Spacer()
                HStack(spacing: 6) {
                    Circle()
                        .fill(ledColor(for: viewModel.activeProtocol))
                        .frame(width: 7, height: 7)
                    Text(activeProtocolTagText(for: viewModel.activeProtocol))
                        .font(.system(size: 13, weight: .semibold, design: .monospaced))
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 5)
                .background(Capsule().fill(Color.primary.opacity(0.12)))
            }

            HStack {
                Text("Preferred Protocol")
                Spacer()
                HStack(spacing: 6) {
                    Circle()
                        .fill(viewModel.preferredProtocol != nil ? ledColor(for: viewModel.preferredProtocol!) : Color.gray)
                        .frame(width: 7, height: 7)
                    Text(viewModel.preferredProtocol != nil ? activeProtocolTagText(for: viewModel.preferredProtocol!) : "None")
                        .font(.system(size: 13, weight: .semibold, design: .monospaced))
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 5)
                .background(Capsule().fill(Color.primary.opacity(0.12)))
            }
            .contextMenu {
                if viewModel.preferredProtocol != nil {
                    SwiftUI.Button(role: .destructive) {
                        viewModel.clearPreferred()
                    } label: {
                        Label("Clear Preferred Protocol", systemImage: "star.slash")
                    }
                }
            }
        }
    }

    private func pairingFileSection(for proto: PairingProtocol, showHeader: Bool) -> some View {
        let fileURL = PairingFileManager.shared.pairingFileURL(for: proto)
        let metadata = PairingFileManager.shared.metadata(for: proto)
        let isInstalled = metadata.exists
        let content = isInstalled ? PairingFileManager.shared.fetchPairingFile(for: proto) : nil

        let parsed = content != nil ? (try? PairingFileManager.shared.parse(content: content!, preferred: proto)) : nil
        let remoteRP = parsed as? RPPairingFile
        let lockdown = parsed as? LockdownPairingFile
        let isValid = parsed != nil

        return Section {
            if isInstalled {
                NavigationLink(destination: PairingFileDetailView(mode: proto)) {
                    HStack(spacing: 12) {
                        Image(systemName: proto == .rppairing ? "bolt.horizontal.circle.fill" : "lock.shield.fill")
                            .font(.system(size: 22))
                            .foregroundColor(proto == .rppairing ? .cyan : .green)

                        Text(proto == .rppairing ? "Remote Pairing File" : "Lockdown Pairing File")
                            .font(.headline)

                        Spacer()

                        statusBadge(text: isValid ? "Configured" : "Invalid", color: isValid ? .green : .orange)
                    }
                    .padding(.vertical, 4)
                }
                .contextMenu {
                    if isValid {
                        if UserDefaults.standard.isMinimuxerBackendHotswapEnabled && proto != viewModel.activeProtocol {
                            SwiftUI.Button {
                                Task {
                                    await viewModel.activate(proto: proto)
                                }
                            } label: {
                                Label("Activate", systemImage: "bolt.fill")
                            }
                        }

                        if proto != viewModel.preferredProtocol {
                            SwiftUI.Button {
                                viewModel.setPreferred(proto: proto)
                            } label: {
                                Label("Set as Preferred", systemImage: "star.fill")
                            }
                        } else {
                            SwiftUI.Button {
                                viewModel.clearPreferred()
                            } label: {
                                Label("Remove as Preferred", systemImage: "star.slash")
                            }
                        }

                        if proto == viewModel.activeProtocol {
                            SwiftUI.Button { } label: {
                                Label("Currently Active", systemImage: "checkmark.circle.fill")
                            }
                            .disabled(true)
                        }
                    }

                    SwiftUI.Button {
                        viewModel.promptImport(for: proto)
                    } label: {
                        Label("Import / Replace File", systemImage: "square.and.arrow.down")
                    }

                    SwiftUI.Button(role: .destructive) {
                        viewModel.confirmDelete(for: proto)
                    } label: {
                        Label("Delete Pairing File", systemImage: "trash")
                    }
                }

                infoRow(label: "File Name", value: fileURL.lastPathComponent, isMonospaced: true)

                if proto == viewModel.activeProtocol || proto == viewModel.preferredProtocol {
                    protocolStatusRow(for: proto)
                }

                if proto == .rppairing {
                    if let id = remoteRP?.identifier, !id.isEmpty {
                        identifierRow(label: "Identifier", value: id, fieldKey: "rp_identifier")
                    }
                    infoRow(label: "Key Material", value: (remoteRP?.publicKey != nil && remoteRP?.privateKey != nil) ? "Public & Private Keys OK" : "Incomplete Keys")
                } else {
                    if let sysBUID = lockdown?.systemBUID, !sysBUID.isEmpty {
                        identifierRow(label: "SystemBUID", value: sysBUID, fieldKey: "lockdown_sysbuid")
                    }
                    if let hostID = lockdown?.hostID, !hostID.isEmpty {
                        identifierRow(label: "HostID", value: hostID, fieldKey: "lockdown_hostid")
                    }
                    if let udid = lockdown?.udid, !udid.isEmpty {
                        identifierRow(label: "Hardware UDID", value: udid, fieldKey: "lockdown_udid")
                    }
                    if let wifi = lockdown?.wifiMACAddress, !wifi.isEmpty {
                        identifierRow(label: "WiFi MAC", value: wifi, fieldKey: "lockdown_wifi")
                    }
                }

                infoRow(label: "File Size", value: ByteCountFormatter.string(fromByteCount: metadata.size, countStyle: .file))
                if let created = metadata.creationDate {
                    infoRow(label: "Date Created", value: formatDate(created))
                }
                if let mod = metadata.modificationDate {
                    infoRow(label: "Date Modified", value: formatDate(mod))
                }
            } else {
                SwiftUI.Button {
                    viewModel.promptImport(for: proto)
                } label: {
                    HStack(spacing: 12) {
                        Image(systemName: proto == .rppairing ? "bolt.horizontal.circle" : "lock.shield")
                            .font(.system(size: 22))
                            .foregroundColor(.secondary)

                        Text(proto == .rppairing ? "Remote Pairing File" : "Lockdown Pairing File")
                            .font(.headline)
                            .foregroundColor(.primary)

                        Spacer()

                        statusBadge(text: "Missing", color: .red)

                        Image(systemName: "square.and.arrow.down")
                            .font(.system(size: 14, weight: .semibold))
                            .foregroundColor(.accentColor)
                    }
                    .padding(.vertical, 4)
                }
                .buttonStyle(.plain)
                .contextMenu {
                    SwiftUI.Button {
                        viewModel.promptImport(for: proto)
                    } label: {
                        Label("Import Pairing File", systemImage: "square.and.arrow.down")
                    }
                }

                infoRow(label: "File Name", value: fileURL.lastPathComponent, isMonospaced: true)
            }
        } header: {
            if showHeader {
                Text("PAIRING FILES")
            }
        }
    }

    private func statusBadge(text: LocalizedStringKey, color: Color) -> some View {
        Text(text)
            .font(.system(size: 12, weight: .semibold))
            .foregroundColor(color)
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .background(color.opacity(0.15))
            .cornerRadius(6)
    }

    private func identifierRow(label: LocalizedStringKey, value: String, fieldKey: String) -> some View {
        let isRevealed = !viewModel.isGlobalHideActive || viewModel.revealedFieldKeys.contains(fieldKey)
        let displayValue = isRevealed ? value : "••••••••••••••••"

        return SwiftUI.Button {
            viewModel.toggleReveal(for: fieldKey)
        } label: {
            HStack {
                Text(label)
                    .foregroundColor(.secondary)
                Spacer()
                Text(displayValue)
                    .font(.system(size: 13, weight: .medium, design: isRevealed ? .monospaced : .default))
                    .foregroundColor(.primary)
            }
        }
        .buttonStyle(.plain)
    }

    private func infoRow(label: LocalizedStringKey, value: String, isMonospaced: Bool = false) -> some View {
        HStack {
            Text(label)
                .foregroundColor(.secondary)
            Spacer()
            Text(value)
                .font(.system(size: 13, weight: .medium, design: isMonospaced ? .monospaced : .default))
                .foregroundColor(.primary)
                .lineLimit(1)
                .minimumScaleFactor(0.8)
        }
    }

    @ViewBuilder
    private func protocolStatusRow(for proto: PairingProtocol) -> some View {
        HStack {
            Text("Status")
                .foregroundColor(.secondary)

            Spacer()

            HStack(spacing: 8) {
                if proto == viewModel.activeProtocol {
                    HStack(spacing: 6) {
                        Circle()
                            .fill(ledColor(for: proto))
                            .frame(width: 7, height: 7)
                        Text("Active")
                            .font(.system(size: 13, weight: .semibold, design: .monospaced))
                    }
                    .padding(.horizontal, 10)
                    .padding(.vertical, 5)
                    .background(Capsule().fill(Color.primary.opacity(0.12)))
                }

                if proto == viewModel.preferredProtocol {
                    HStack(spacing: 6) {
                        Circle()
                            .fill(Color.yellow)
                            .frame(width: 7, height: 7)
                        Text("Preferred")
                            .font(.system(size: 13, weight: .semibold, design: .monospaced))
                    }
                    .padding(.horizontal, 10)
                    .padding(.vertical, 5)
                    .background(Capsule().fill(Color.primary.opacity(0.12)))
                }
            }
        }
    }

    private var pairingMethodsSection: some View {
        Section(header: Text("PAIRING METHODS")) {
            NavigationLink(destination: WirelessPairView()) {
                HStack(spacing: 12) {
                    Image(systemName: "antenna.radiowaves.left.and.right")
                        .font(.system(size: 18, weight: .semibold))
                    Text("Wireless Pairing")
                        .font(.headline)
                }
                .padding(.vertical, 4)
            }
        }
    }

    private var managementSection: some View {
        Section(
            header: Text("MANAGEMENT"),
            footer: Text("Resetting pairing files removes stored Lockdown and Remote Pairing credentials. You will need to re-pair or re-import a pairing file and restart SideStore.")
                .font(.footnote)
        ) {
            SwiftUI.Button(role: .destructive, action: {
                viewModel.confirmReset()
            }) {
                HStack(spacing: 12) {
                    Image(systemName: "arrow.counterclockwise.circle")
                        .font(.system(size: 18, weight: .semibold))
                    Text("Reset Pairing Files")
                        .font(.headline)
                }
                .padding(.vertical, 4)
            }
        }
    }

    private func ledColor(for proto: PairingProtocol) -> Color {
        switch proto {
        case .lockdown:
            return .green
        case .rppairing:
            return .cyan
        case .unknown:
            return .orange
        }
    }

    private func activeProtocolTagText(for proto: PairingProtocol) -> String {
        switch proto {
        case .lockdown:
            return "lockdown"
        case .rppairing:
            return "rppairing"
        case .unknown:
            return "unknown"
        }
    }

    private func formatDate(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .short
        return formatter.string(from: date)
    }
}
