//
//  DevicesListView.swift
//  SideStore
//
//  Created by Magesh K on 2/9/26.
//  Copyright © 2026 SideStore. All rights reserved.
//

import SwiftUI
import SideSign

enum ActiveDeviceAlert: Identifiable {
    case disable(ALTDevice)
    case delete(ALTDevice)

    var id: String {
        switch self {
        case .disable(let dev): return "disable-\(dev.identifier)"
        case .delete(let dev): return "delete-\(dev.identifier)"
        }
    }
}

struct DevicesListView: View {
    @ObservedObject var viewModel: DeveloperServicesViewModel
    weak var presentingViewController: UIViewController?

    @State private var searchText = ""
    @State private var showRegisterSheet = false
    @State private var newDeviceName = ""
    @State private var newDeviceUDID = ""
    @State private var selectedDeviceType: ALTDeviceType = DeveloperPortalProxy.currentDeviceType
    @State private var isFetchingUDID = false

    @State private var deviceToEdit: ALTDevice? = nil
    @State private var editDeviceName = ""
    @State private var showSheetDeleteAlert = false
    @State private var showSheetDisableAlert = false

    @State private var activeAlert: ActiveDeviceAlert? = nil

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
            Section(header: Text(String(format: NSLocalizedString("Registered Devices (%d)", comment: ""), viewModel.devices.count)), footer: Text(NSLocalizedString("Devices registered on your developer team can run development-signed apps. Tap any device to edit its name, disable, or delete it.", comment: ""))) {
                if filteredDevices.isEmpty {
                    if viewModel.isLoading {
                        HStack {
                            Spacer()
                            ProgressView()
                            Spacer()
                        }
                        .padding(.vertical, 8)
                    } else {
                        Text(searchText.isEmpty ? NSLocalizedString("No devices registered on Developer Portal.", comment: "") : NSLocalizedString("No matching devices found.", comment: ""))
                            .foregroundColor(.secondary)
                            .font(.subheadline)
                    }
                } else {
                    ForEach(filteredDevices, id: \.self) { device in
                        SwiftUI.Button {
                            editDeviceName = device.name
                            deviceToEdit = device
                        } label: {
                            VStack(alignment: .leading, spacing: 4) {
                                HStack {
                                    Text(device.name.isEmpty ? NSLocalizedString("Device", comment: "") : device.name)
                                        .font(.headline)
                                        .foregroundColor(.primary)
                                    Spacer()
                                    if device.status == "d" {
                                        Text(NSLocalizedString("Disabled", comment: ""))
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
                        #if !os(tvOS)
                        .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                            SwiftUI.Button(role: .destructive) {
                                activeAlert = .delete(device)
                            } label: {
                                Label(NSLocalizedString("Delete", comment: ""), systemImage: "trash")
                            }

                            if device.status != "d" {
                                SwiftUI.Button {
                                    activeAlert = .disable(device)
                                } label: {
                                    Label(NSLocalizedString("Disable", comment: ""), systemImage: "slash.circle")
                                }
                                .tint(.orange)
                            }

                            SwiftUI.Button {
                                editDeviceName = device.name
                                deviceToEdit = device
                            } label: {
                                Label(NSLocalizedString("Edit", comment: ""), systemImage: "pencil")
                            }
                            .tint(.blue)
                        }
                        #endif
                        .contextMenu {
                            SwiftUI.Button {
                                editDeviceName = device.name
                                deviceToEdit = device
                            } label: {
                                Label(NSLocalizedString("Edit Name", comment: ""), systemImage: "pencil")
                            }
                            #if !os(tvOS)
                            SwiftUI.Button {
                                UIPasteboard.general.string = device.identifier
                            } label: {
                                Label(NSLocalizedString("Copy UDID", comment: ""), systemImage: "doc.on.doc")
                            }
                            #endif
                            if device.status != "d" {
                                SwiftUI.Button {
                                    activeAlert = .disable(device)
                                } label: {
                                    Label(NSLocalizedString("Disable Device", comment: ""), systemImage: "slash.circle")
                                }
                            }
                            SwiftUI.Button(role: .destructive) {
                                activeAlert = .delete(device)
                            } label: {
                                Label(NSLocalizedString("Delete Device", comment: ""), systemImage: "trash")
                            }
                        }
                    }
                }
            }
        }
        #if !os(tvOS)
        .listStyle(InsetGroupedListStyle())
        .searchable(text: $searchText, placement: .navigationBarDrawer(displayMode: .automatic), prompt: Text(NSLocalizedString("Search Devices", comment: "")))
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
            await viewModel.fetchDevices(presentingViewController: presentingViewController, isPullToRefresh: true)
        }
        .sheet(isPresented: $showRegisterSheet) {
            NavigationView {
                Form {
                    Section(header: Text(NSLocalizedString("Device Information", comment: "")), footer: Text(NSLocalizedString("UDID is a 25-character or 40-character unique device identifier.", comment: ""))) {
                        TextField(NSLocalizedString("Device Name", comment: ""), text: $newDeviceName)
                        TextField(NSLocalizedString("Device UDID", comment: ""), text: $newDeviceUDID)
                            .autocapitalization(.none)
                            .disableAutocorrection(true)

                        Picker(NSLocalizedString("Device Type", comment: ""), selection: $selectedDeviceType) {
                            Text(NSLocalizedString("iPhone", comment: "")).tag(ALTDeviceType.iphone)
                            Text(NSLocalizedString("iPad", comment: "")).tag(ALTDeviceType.ipad)
                            Text(NSLocalizedString("Apple TV", comment: "")).tag(ALTDeviceType.appleTV)
                            Text(NSLocalizedString("Apple Watch", comment: "")).tag(ALTDeviceType.appleWatch)
                            Text(NSLocalizedString("Mac", comment: "")).tag(ALTDeviceType.mac)
                            Text(NSLocalizedString("Vision Pro", comment: "")).tag(ALTDeviceType.visionPro)
                        }
                    }

                    Section {
                        SwiftUI.Button {
                            #if !os(tvOS)
                            newDeviceName = UIDevice.current.name
                            if UIDevice.current.userInterfaceIdiom == .pad {
                                selectedDeviceType = .ipad
                            } else {
                                selectedDeviceType = .iphone
                            }
                            #else
                            newDeviceName = "Apple TV"
                            selectedDeviceType = .appleTV
                            #endif
                        } label: {
                            HStack {
                                Image(systemName: "pencil")
                                Text(NSLocalizedString("Fill Current Device Name", comment: ""))
                            }
                        }

                        SwiftUI.Button {
                            Task {
                                isFetchingUDID = true
                                defer { isFetchingUDID = false }
                                if let foundUDID = try? await safeFetchUDID() {
                                    newDeviceUDID = foundUDID
                                    if newDeviceName.isEmpty {
                                        #if !os(tvOS)
                                        newDeviceName = UIDevice.current.name
                                        #else
                                        newDeviceName = "Apple TV"
                                        #endif
                                    }
                                    #if !os(tvOS)
                                    if UIDevice.current.userInterfaceIdiom == .pad {
                                        selectedDeviceType = .ipad
                                    } else {
                                        selectedDeviceType = .iphone
                                    }
                                    #endif
                                    viewModel.showToastMessage(String(format: NSLocalizedString("Fetched Device UDID: %@", comment: ""), "\(foundUDID.prefix(8))..."))
                                } else {
                                    viewModel.showToastMessage(NSLocalizedString("Current Device UDID not available", comment: ""))
                                }
                            }
                        } label: {
                            HStack {
                                if isFetchingUDID {
                                    ProgressView()
                                        .padding(.trailing, 4)
                                } else {
                                    Image(systemName: "iphone.and.arrow.forward")
                                }
                                Text(NSLocalizedString("Fetch Current Device UDID", comment: ""))
                            }
                        }
                        .disabled(isFetchingUDID)
                    }
                }
                .navigationTitle(NSLocalizedString("Register Device", comment: ""))
                .navigationBarItems(
                    leading: SwiftUI.Button(NSLocalizedString("Cancel", comment: "")) {
                        showRegisterSheet = false
                    },
                    trailing: SwiftUI.Button(NSLocalizedString("Register", comment: "")) {
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
                .developerServicesToast(viewModel: viewModel)
            }
        }
        .sheet(item: $deviceToEdit) { device in
            NavigationView {
                Form {
                    Section(header: Text(NSLocalizedString("Device Name", comment: ""))) {
                        TextField(NSLocalizedString("Device Name", comment: ""), text: $editDeviceName)
                    }

                    Section(header: Text(NSLocalizedString("Device Identifier (UDID)", comment: ""))) {
                        Text(device.identifier.isEmpty ? NSLocalizedString("Not Available", comment: "") : device.identifier)
                            .font(.system(.subheadline, design: .monospaced))
                            .foregroundColor(.secondary)
                    }

                    Section(header: Text(NSLocalizedString("Device Details", comment: ""))) {
                        InfoRow(label: NSLocalizedString("Type", comment: ""), value: device.type.displayName)
                        InfoRow(label: NSLocalizedString("Status", comment: ""), value: device.status == "d" ? NSLocalizedString("Disabled", comment: "") : NSLocalizedString("Active", comment: ""), valueColor: device.status == "d" ? .red : .green)
                        if let devID = device.deviceID, !devID.isEmpty {
                            InfoRow(label: NSLocalizedString("Portal ID", comment: ""), value: devID)
                        }
                    }

                    Section {
                        if device.status != "d" {
                            SwiftUI.Button {
                                showSheetDisableAlert = true
                            } label: {
                                HStack {
                                    Spacer()
                                    Image(systemName: "slash.circle")
                                    Text(NSLocalizedString("Disable Device", comment: ""))
                                        .fontWeight(.semibold)
                                    Spacer()
                                }
                                .foregroundColor(.orange)
                            }
                        }

                        SwiftUI.Button(role: .destructive) {
                            showSheetDeleteAlert = true
                        } label: {
                            HStack {
                                Spacer()
                                Image(systemName: "trash")
                                Text(NSLocalizedString("Delete Device", comment: ""))
                                    .fontWeight(.semibold)
                                Spacer()
                            }
                        }
                    }
                }
                .navigationTitle(NSLocalizedString("Edit Device", comment: ""))
                .navigationBarItems(
                    leading: SwiftUI.Button(NSLocalizedString("Cancel", comment: "")) {
                        deviceToEdit = nil
                    },
                    trailing: SwiftUI.Button(NSLocalizedString("Save", comment: "")) {
                        let trimmed = editDeviceName.trimmingCharacters(in: .whitespacesAndNewlines)
                        guard !trimmed.isEmpty else { return }
                        Task {
                            let success = await viewModel.updateDevice(device, newName: trimmed, presentingViewController: presentingViewController)
                            if success {
                                deviceToEdit = nil
                            }
                        }
                    }
                    .disabled(editDeviceName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ||
                              editDeviceName == device.name ||
                              viewModel.isActionLoading)
                )
                .alert(isPresented: $showSheetDisableAlert) {
                    Alert(
                        title: Text(NSLocalizedString("Disable Device?", comment: "")),
                        message: Text(String(format: NSLocalizedString("Are you sure you want to disable '%@'? It will no longer be included in newly generated provisioning profiles.", comment: ""), device.name)),
                        primaryButton: .default(Text(NSLocalizedString("Disable", comment: ""))) {
                            Task {
                                let success = await viewModel.disableDevice(device, presentingViewController: presentingViewController)
                                if success {
                                    deviceToEdit = nil
                                }
                            }
                        },
                        secondaryButton: .cancel()
                    )
                }
                .alert(isPresented: $showSheetDeleteAlert) {
                    Alert(
                        title: Text(NSLocalizedString("Delete Device?", comment: "")),
                        message: Text(String(format: NSLocalizedString("Are you sure you want to delete '%@' from the Apple Developer Portal? This action cannot be undone.", comment: ""), device.name)),
                        primaryButton: .destructive(Text(NSLocalizedString("Delete", comment: ""))) {
                            Task {
                                let success = await viewModel.deleteDevice(device, presentingViewController: presentingViewController)
                                if success {
                                    deviceToEdit = nil
                                }
                            }
                        },
                        secondaryButton: .cancel()
                    )
                }
            }
        }
        .alert(item: $activeAlert) { alert in
            switch alert {
            case .disable(let device):
                return Alert(
                    title: Text(NSLocalizedString("Disable Device?", comment: "")),
                    message: Text(String(format: NSLocalizedString("Are you sure you want to disable '%@'? It will no longer be included in newly generated provisioning profiles.", comment: ""), device.name)),
                    primaryButton: .default(Text(NSLocalizedString("Disable", comment: ""))) {
                        Task {
                            _ = await viewModel.disableDevice(device, presentingViewController: presentingViewController)
                        }
                    },
                    secondaryButton: .cancel()
                )
            case .delete(let device):
                return Alert(
                    title: Text(NSLocalizedString("Delete Device?", comment: "")),
                    message: Text(String(format: NSLocalizedString("Are you sure you want to delete '%@' from the Apple Developer Portal? This action cannot be undone.", comment: ""), device.name)),
                    primaryButton: .destructive(Text(NSLocalizedString("Delete", comment: ""))) {
                        Task {
                            _ = await viewModel.deleteDevice(device, presentingViewController: presentingViewController)
                        }
                    },
                    secondaryButton: .cancel()
                )
            }
        }
        .developerServicesToast(viewModel: viewModel)
    }
}
