//
//  DevicesListView.swift
//  SideStore
//
//  Created by Magesh K on 2/9/26.
//  Copyright © 2026 SideStore. All rights reserved.
//

import SwiftUI
import SideSign

struct DevicesListView: View {
    @ObservedObject var viewModel: DeveloperServicesViewModel
    weak var presentingViewController: UIViewController?

    @State private var searchText = ""
    @State private var showRegisterSheet = false
    @State private var newDeviceName = ""
    @State private var newDeviceUDID = ""
    @State private var selectedDeviceType: ALTDeviceType = .iphone

    @State private var deviceToEdit: ALTDevice? = nil
    @State private var editDeviceName = ""
    @State private var showEditSheet = false

    @State private var deviceToDisable: ALTDevice? = nil
    @State private var showDisableConfirmation = false

    @State private var deviceToDelete: ALTDevice? = nil
    @State private var showDeleteConfirmation = false

    private var filteredDevices: [ALTDevice] {
        if searchText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return viewModel.devices
        }
        return viewModel.devices.filter {
            $0.name.localizedCaseInsensitiveContains(searchText) ||
            $0.identifier.localizedCaseInsensitiveContains(searchText) ||
            $0.type.displayName.localizedCaseInsensitiveContains(searchText)
        }
    }

    var body: some View {
        List {
            Section(header: Text(String(format: NSLocalizedString("Registered Devices (%@)", comment: ""), "\(viewModel.devices.count)")), footer: Text(LocalizedStringKey("Devices registered on your developer team can run development-signed apps. Tap any device to edit its name, disable, or delete it."))) {
                if filteredDevices.isEmpty {
                    if viewModel.isLoading {
                        HStack {
                            Spacer()
                            ProgressView()
                            Spacer()
                        }
                        .padding(.vertical, 8)
                    } else {
                        Text(LocalizedStringKey(searchText.isEmpty ? "No devices registered on Developer Portal." : "No matching devices found."))
                            .foregroundColor(.secondary)
                            .font(.subheadline)
                    }
                } else {
                    ForEach(filteredDevices, id: \.identifier) { device in
                        SwiftUI.Button {
                            deviceToEdit = device
                            editDeviceName = device.name
                            showEditSheet = true
                        } label: {
                            VStack(alignment: .leading, spacing: 4) {
                                HStack {
                                    Text(device.name.isEmpty ? "Device" : device.name)
                                        .font(.headline)
                                        .foregroundColor(.primary)
                                    Spacer()
                                    if device.status == "d" {
                                        Text("Disabled")
                                            .font(.caption2)
                                            .padding(.horizontal, 6)
                                            .padding(.vertical, 2)
                                            .background(Color.red.opacity(0.15))
                                            .foregroundColor(.red)
                                            .cornerRadius(6)
                                    }
                                    Text(device.type.displayName)
                                        .font(.caption2)
                                        .padding(.horizontal, 6)
                                        .padding(.vertical, 2)
                                        .background(Color.secondary.opacity(0.15))
                                        .foregroundColor(.secondary)
                                        .cornerRadius(6)
                                    Image(systemName: "chevron.right")
                                        .font(.caption)
                                        .foregroundColor(.secondary)
                                }
                                Text(device.identifier)
                                    .font(.system(.caption, design: .monospaced))
                                    .foregroundColor(.secondary)
                            }
                            .padding(.vertical, 2)
                        }
                        .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                            SwiftUI.Button(role: .destructive) {
                                deviceToDelete = device
                                showDeleteConfirmation = true
                            } label: {
                                Label("Delete", systemImage: "trash")
                            }

                            if device.status != "d" {
                                SwiftUI.Button {
                                    deviceToDisable = device
                                    showDisableConfirmation = true
                                } label: {
                                    Label("Disable", systemImage: "slash.circle")
                                }
                                .tint(.orange)
                            }

                            SwiftUI.Button {
                                deviceToEdit = device
                                editDeviceName = device.name
                                showEditSheet = true
                            } label: {
                                Label("Edit", systemImage: "pencil")
                            }
                            .tint(.blue)
                        }
                        #if !os(tvOS)
                        .contextMenu {
                            SwiftUI.Button {
                                deviceToEdit = device
                                editDeviceName = device.name
                                showEditSheet = true
                            } label: {
                                Label("Edit Name", systemImage: "pencil")
                            }
                            SwiftUI.Button {
                                UIPasteboard.general.string = device.identifier
                            } label: {
                                Label("Copy UDID", systemImage: "doc.on.doc")
                            }
                            if device.status != "d" {
                                SwiftUI.Button {
                                    deviceToDisable = device
                                    showDisableConfirmation = true
                                } label: {
                                    Label("Disable Device", systemImage: "slash.circle")
                                }
                            }
                            SwiftUI.Button(role: .destructive) {
                                deviceToDelete = device
                                showDeleteConfirmation = true
                            } label: {
                                Label("Delete Device", systemImage: "trash")
                            }
                        }
                        #endif
                    }
                }
            }
        }
        #if !os(tvOS)
        .listStyle(InsetGroupedListStyle())
        .searchable(text: $searchText, placement: .navigationBarDrawer(displayMode: .automatic), prompt: Text("Search Devices"))
        #else
        .listStyle(GroupedListStyle())
        #endif
        .navigationTitle(NSLocalizedString("Devices", comment: ""))
        .toolbar {
            ToolbarItem(placement: .navigationBarTrailing) {
                SwiftUI.Button {
                    newDeviceName = ""
                    newDeviceUDID = ""
                    selectedDeviceType = .iphone
                    showRegisterSheet = true
                } label: {
                    Image(systemName: "plus")
                }
            }
        }
        .refreshable {
            await viewModel.fetchDevices(presentingViewController: presentingViewController)
        }
        .sheet(isPresented: $showRegisterSheet) {
            NavigationView {
                Form {
                    Section(header: Text("Device Information"), footer: Text(LocalizedStringKey("UDID is a 25-character or 40-character unique device identifier."))) {
                        TextField(NSLocalizedString("Device Name (e.g. John's iPhone)", comment: ""), text: $newDeviceName)
                        TextField(NSLocalizedString("Device UDID", comment: ""), text: $newDeviceUDID)
                            .autocapitalization(.none)
                            .disableAutocorrection(true)

                        Picker(NSLocalizedString("Device Type", comment: ""), selection: $selectedDeviceType) {
                            Text("iPhone").tag(ALTDeviceType.iphone)
                            Text("iPad").tag(ALTDeviceType.ipad)
                            Text("Apple TV").tag(ALTDeviceType.appleTV)
                            Text("Apple Watch").tag(ALTDeviceType.appleWatch)
                            Text("Mac").tag(ALTDeviceType.mac)
                            Text("Vision Pro").tag(ALTDeviceType.visionPro)
                        }
                    }

                    Section {
                        SwiftUI.Button {
                            #if !os(tvOS)
                            newDeviceName = UIDevice.current.name
                            #else
                            newDeviceName = "Apple TV"
                            #endif
                        } label: {
                            HStack {
                                Image(systemName: "iphone")
                                Text(LocalizedStringKey("Fill Current Device Name"))
                            }
                        }
                    }
                }
                .navigationTitle(NSLocalizedString("Register Device", comment: ""))
                .navigationBarItems(
                    leading: SwiftUI.Button("Cancel") {
                        showRegisterSheet = false
                    },
                    trailing: SwiftUI.Button("Register") {
                        let name = newDeviceName.trimmingCharacters(in: .whitespacesAndNewlines)
                        let udid = newDeviceUDID.trimmingCharacters(in: .whitespacesAndNewlines)
                        guard !name.isEmpty, !udid.isEmpty else { return }
                        Task {
                            let success = await viewModel.registerDevice(name: name, identifier: udid, type: selectedDeviceType, presentingViewController: presentingViewController)
                            if success {
                                showRegisterSheet = false
                            }
                        }
                    }
                    .disabled(newDeviceName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ||
                              newDeviceUDID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ||
                              viewModel.isActionLoading)
                )
            }
        }
        .sheet(isPresented: $showEditSheet) {
            NavigationView {
                Form {
                    Section(header: Text("Device Name")) {
                        TextField(NSLocalizedString("Device Name", comment: ""), text: $editDeviceName)
                    }

                    Section(header: Text("Device Identifier (UDID)")) {
                        Text(deviceToEdit?.identifier ?? "")
                            .font(.system(.subheadline, design: .monospaced))
                            .foregroundColor(.secondary)
                    }

                    Section(header: Text("Device Details")) {
                        InfoRow(label: NSLocalizedString("Device Type", comment: ""), value: deviceToEdit?.type.displayName ?? "Device")
                        InfoRow(label: NSLocalizedString("Status", comment: ""), value: deviceToEdit?.status == "d" ? NSLocalizedString("Disabled", comment: "") : NSLocalizedString("Active", comment: ""), valueColor: deviceToEdit?.status == "d" ? .red : .green)
                        if let devID = deviceToEdit?.deviceID {
                            InfoRow(label: NSLocalizedString("Portal ID", comment: ""), value: devID)
                        }
                    }

                    Section {
                        if deviceToEdit?.status != "d" {
                            SwiftUI.Button {
                                if let target = deviceToEdit {
                                    showEditSheet = false
                                    deviceToDisable = target
                                    showDisableConfirmation = true
                                }
                            } label: {
                                HStack {
                                    Spacer()
                                    Image(systemName: "slash.circle")
                                    Text("Disable Device")
                                        .fontWeight(.semibold)
                                    Spacer()
                                }
                                .foregroundColor(.orange)
                            }
                        }

                        SwiftUI.Button(role: .destructive) {
                            if let target = deviceToEdit {
                                showEditSheet = false
                                deviceToDelete = target
                                showDeleteConfirmation = true
                            }
                        } label: {
                            HStack {
                                Spacer()
                                Image(systemName: "trash")
                                Text("Delete Device")
                                    .fontWeight(.semibold)
                                Spacer()
                            }
                        }
                    }
                }
                .navigationTitle(NSLocalizedString("Edit Device Configuration", comment: ""))
                .navigationBarItems(
                    leading: SwiftUI.Button("Cancel") {
                        showEditSheet = false
                    },
                    trailing: SwiftUI.Button("Save") {
                        let trimmed = editDeviceName.trimmingCharacters(in: .whitespacesAndNewlines)
                        guard let target = deviceToEdit, !trimmed.isEmpty else { return }
                        Task {
                            let success = await viewModel.updateDevice(target, newName: trimmed, presentingViewController: presentingViewController)
                            if success {
                                showEditSheet = false
                            }
                        }
                    }
                    .disabled(editDeviceName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ||
                              editDeviceName == deviceToEdit?.name ||
                              viewModel.isActionLoading)
                )
            }
        }
        .alert(isPresented: $showDisableConfirmation) {
            Alert(
                title: Text("Disable Device?"),
                message: Text(String(format: NSLocalizedString("Are you sure you want to disable '%@'? It can only be re-enabled during your annual membership renewal period.", comment: ""), deviceToDisable?.name ?? "this device")),
                primaryButton: .default(Text("Disable")) {
                    if let target = deviceToDisable {
                        Task {
                            _ = await viewModel.disableDevice(target, presentingViewController: presentingViewController)
                        }
                    }
                },
                secondaryButton: .cancel()
            )
        }
        .alert(isPresented: $showDeleteConfirmation) {
            Alert(
                title: Text("Delete Device?"),
                message: Text(String(format: NSLocalizedString("Are you sure you want to delete '%@' (%@) from Apple Developer Portal?", comment: ""), deviceToDelete?.name ?? "this device", deviceToDelete?.identifier ?? "")),
                primaryButton: .destructive(Text("Delete")) {
                    if let target = deviceToDelete {
                        Task {
                            _ = await viewModel.deleteDevice(target, presentingViewController: presentingViewController)
                        }
                    }
                },
                secondaryButton: .cancel()
            )
        }
    }
}
