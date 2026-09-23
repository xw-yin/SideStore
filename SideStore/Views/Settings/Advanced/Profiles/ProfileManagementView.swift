//
//  ProfileManagementView.swift
//  SideStore
//
//  Created by Magesh K on 14/9/26.
//  Copyright © 2026 SideStore. All rights reserved.
//

import SwiftUI
import SideSign
import UniformTypeIdentifiers

struct PendingProfileImport: Identifiable {
    let id = UUID()
    let profile: ALTProvisioningProfile
    let analysis: ProfileManager.CertificateAnalysisResult
}

struct ProfileManagementView: View {
    weak var presentingViewController: UIViewController?

    @StateObject private var viewModel = ProfileManagementViewModel()
    @StateObject private var certificatesViewModel = CertificatesViewModel()
    @StateObject private var devServicesViewModel = DeveloperServicesViewModel()

    @State private var searchText = ""
    @State private var showFileImporter = false
    @State private var profileToDelete: ALTProvisioningProfile? = nil
    @State private var showDeleteConfirmation = false
    @State private var showPortalDeleteConfirmation = false
    @State private var profileToShareURL: URL? = nil
    @State private var pendingImport: PendingProfileImport? = nil
    @State private var profileToEditOnPortal: ALTListedProvisioningProfile? = nil
    @State private var showAddOptions = false
    @State private var navigateToPortalProfiles = false

    private var allowedImportTypes: [UTType] {
        [UTType(filenameExtension: "mobileprovision")].compactMap { $0 }
    }

    private var filteredProfiles: [ALTProvisioningProfile] {
        if searchText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return viewModel.profiles
        }
        return viewModel.profiles.filter {
            $0.name.localizedCaseInsensitiveContains(searchText) ||
            $0.bundleIdentifier.localizedCaseInsensitiveContains(searchText) ||
            $0.teamName.localizedCaseInsensitiveContains(searchText) ||
            $0.uuid.uuidString.localizedCaseInsensitiveContains(searchText)
        }
    }

    var body: some View {
        ZStack {
            List {
                Section(header: Text(NSLocalizedString("Overview", comment: ""))) {
                    HStack {
                        VStack(alignment: .leading, spacing: 4) {
                            Text(NSLocalizedString("Total", comment: ""))
                                .font(.caption)
                                .foregroundColor(.secondary)
                            Text("\(viewModel.profiles.count)")
                                .font(.title2)
                                .fontWeight(.bold)
                        }
                        Spacer()
                        VStack(alignment: .leading, spacing: 4) {
                            Text(NSLocalizedString("Ready", comment: ""))
                                .font(.caption)
                                .foregroundColor(.secondary)
                            Text("\(viewModel.readyCount)")
                                .font(.title2)
                                .fontWeight(.bold)
                                .foregroundColor(.green)
                        }
                        Spacer()
                        VStack(alignment: .leading, spacing: 4) {
                            Text(NSLocalizedString("Portal", comment: ""))
                                .font(.caption)
                                .foregroundColor(.secondary)
                            Text("\(viewModel.portalCount)")
                                .font(.title2)
                                .fontWeight(.bold)
                                .foregroundColor(.blue)
                        }
                        Spacer()
                        VStack(alignment: .leading, spacing: 4) {
                            Text(NSLocalizedString("Missing Cert", comment: ""))
                                .font(.caption)
                                .foregroundColor(.secondary)
                            Text("\(viewModel.profiles.count - viewModel.readyCount)")
                                .font(.title2)
                                .fontWeight(.bold)
                                .foregroundColor(viewModel.profiles.count - viewModel.readyCount > 0 ? .orange : .secondary)
                        }
                    }
                    .padding(.vertical, 4)
                }

                Section(
                    header: Text(String(format: NSLocalizedString("Provisioning Profiles (%d)", comment: ""), filteredProfiles.count)),
                    footer: Text(NSLocalizedString("Provisioning profiles dictate entitlements, device permissions, and expiration dates. Profiles sync automatically with your developer account.", comment: ""))
                ) {
                    if filteredProfiles.isEmpty {
                        if viewModel.isLoading {
                            HStack {
                                Spacer()
                                ProgressView()
                                Spacer()
                            }
                            .padding(.vertical, 8)
                        } else {
                            Text(searchText.isEmpty ? NSLocalizedString("No provisioning profiles installed. Tap '+' to import or pull to refresh.", comment: "") : NSLocalizedString("No matching provisioning profiles found.", comment: ""))
                                .foregroundColor(.secondary)
                                .font(.subheadline)
                        }
                    } else {
                        ForEach(filteredProfiles, id: \.uuid) { profile in
                            NavigationLink(destination: ProvisioningProfileDetailView(profile: profile, profileURL: ProfileManager.shared.profileURL(for: profile.uuid), certificatesViewModel: certificatesViewModel)) {
                                ProfileManagementRowView(profile: profile, isRemote: viewModel.isRemoteProfile(profile), formatDate: formatDate)
                            }
                            #if !os(tvOS)
                            .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                                SwiftUI.Button(role: .destructive) {
                                    promptDelete(profile)
                                } label: {
                                    Label(NSLocalizedString("Delete", comment: ""), systemImage: "trash")
                                }
                                if viewModel.canEditProfileOnPortal(profile) {
                                    SwiftUI.Button {
                                        if let listed = viewModel.listedProfile(for: profile.uuid) {
                                            profileToEditOnPortal = listed
                                        }
                                    } label: {
                                        Label(NSLocalizedString("Edit", comment: ""), systemImage: "pencil")
                                    }
                                    .tint(.purple)
                                }
                            }
                            .swipeActions(edge: .leading, allowsFullSwipe: false) {
                                SwiftUI.Button {
                                    shareProfile(profile)
                                } label: {
                                    Label(NSLocalizedString("Share", comment: ""), systemImage: "square.and.arrow.up")
                                }
                                .tint(.blue)
                            }
                            #endif
                            .contextMenu {
                                if viewModel.canEditProfileOnPortal(profile) {
                                    SwiftUI.Button {
                                        if let listed = viewModel.listedProfile(for: profile.uuid) {
                                            profileToEditOnPortal = listed
                                        }
                                    } label: {
                                        Label(NSLocalizedString("Edit on Developer Portal", comment: ""), systemImage: "pencil")
                                    }
                                }
                                SwiftUI.Button {
                                    shareProfile(profile)
                                } label: {
                                    Label(NSLocalizedString("Share Profile", comment: ""), systemImage: "square.and.arrow.up")
                                }
                                SwiftUI.Button(role: .destructive) {
                                    promptDelete(profile)
                                } label: {
                                    Label(NSLocalizedString("Delete Profile", comment: ""), systemImage: "trash")
                                }
                            }
                        }
                    }
                }
            }
            #if !os(tvOS)
            .listStyle(InsetGroupedListStyle())
            .searchable(text: $searchText, placement: .navigationBarDrawer(displayMode: .automatic), prompt: Text(NSLocalizedString("Search Profiles", comment: "")))
            #else
            .listStyle(GroupedListStyle())
            #endif

            if let message = viewModel.toastMessage {
                VStack {
                    Spacer()
                    Text(message)
                        .font(.footnote)
                        .padding(.horizontal, 16)
                        .padding(.vertical, 10)
                        .background(Color(.systemGray6))
                        .foregroundColor(.primary)
                        .cornerRadius(20)
                        .shadow(radius: 6)
                        .padding(.bottom, 20)
                        .transition(.move(edge: .bottom).combined(with: .opacity))
                }
                .animation(.easeInOut, value: viewModel.toastMessage)
            }

        }
        .navigationTitle(NSLocalizedString("Profile Management", comment: ""))
        .toolbar {
            ToolbarItem(placement: .navigationBarTrailing) {
                SwiftUI.Button {
                    showAddOptions.toggle()
                } label: {
                    Image(systemName: "plus")
                }
                .accessibilityLabel(NSLocalizedString("Add Provisioning Profile", comment: ""))
                // Anchor the dialog to the + button so the iPad popover arrow points at it.
                .confirmationDialog(
                    NSLocalizedString("Add Provisioning Profile", comment: ""),
                    isPresented: $showAddOptions,
                    titleVisibility: .visible
                ) {
                    SwiftUI.Button(NSLocalizedString("Import from Files", comment: "")) {
                        importProfileAction()
                    }
                    SwiftUI.Button(NSLocalizedString("Create on Developer Portal", comment: "")) {
                        Task {
                            await devServicesViewModel.loadAll(presentingViewController: presentingViewController)
                        }
                        navigateToPortalProfiles = true
                    }
                    SwiftUI.Button(NSLocalizedString("Cancel", comment: ""), role: .cancel) {}
                }
            }
        }
        .onAppear {
            viewModel.loadProfiles(isPullToRefresh: false)
        }
        .refreshable {
            viewModel.loadProfiles(isPullToRefresh: true)
        }
        #if !os(tvOS)
        .fileImporter(
            isPresented: $showFileImporter,
            allowedContentTypes: allowedImportTypes,
            allowsMultipleSelection: false
        ) { result in
            switch result {
            case .success(let urls):
                guard let url = urls.first else { return }
                guard url.startAccessingSecurityScopedResource() else { return }
                defer { url.stopAccessingSecurityScopedResource() }
                handleFileSelected(at: url)
            case .failure(let error):
                viewModel.showToast(String(format: NSLocalizedString("Import canceled: %@", comment: ""), error.localizedDescription))
            }
        }
        .sheet(isPresented: Binding<Bool>(
            get: { profileToShareURL != nil },
            set: { if !$0 { profileToShareURL = nil } }
        )) {
            if let url = profileToShareURL {
                ActivityViewController(activityItems: [url])
            }
        }
        #endif
        .sheet(item: $profileToEditOnPortal) { listed in
            NavigationView {
                ProfilePortalDetailView(profile: listed, viewModel: devServicesViewModel, presentingViewController: presentingViewController)
                    .toolbar {
                        ToolbarItem(placement: .cancellationAction) {
                            SwiftUI.Button(NSLocalizedString("Done", comment: "")) {
                                profileToEditOnPortal = nil
                                viewModel.loadProfiles(isPullToRefresh: true)
                            }
                        }
                    }
            }
        }
        .alert(item: $pendingImport) { pending in
            switch pending.analysis {
            case .signable(let certName, _):
                return Alert(
                    title: Text(NSLocalizedString("Link Signing Certificate?", comment: "")),
                    message: Text(String(format: NSLocalizedString("Found matching signing certificate '%@' with private key in SideStore.\n\nWould you like to link and save this profile?", comment: ""), certName)),
                    primaryButton: .default(Text(NSLocalizedString("Link & Save", comment: ""))) {
                        commitImport(pending.profile)
                    },
                    secondaryButton: .cancel()
                )
            case .publicOnly(let certName, _):
                return Alert(
                    title: Text(NSLocalizedString("Missing Private Key", comment: "")),
                    message: Text(String(format: NSLocalizedString("Found certificate '%@' in this profile, but no matching private key (.p12) was found in SideStore.\n\nContinuing means this profile will not be usable for signing apps until a matching signing certificate with private key is imported.", comment: ""), certName)),
                    primaryButton: .destructive(Text(NSLocalizedString("Import Anyway", comment: ""))) {
                        commitImport(pending.profile)
                    },
                    secondaryButton: .cancel()
                )
            case .noMatch(let count):
                return Alert(
                    title: Text(NSLocalizedString("No Matching Signing Certificate", comment: "")),
                    message: Text(String(format: NSLocalizedString("This provisioning profile contains %d developer certificate(s), but none match any signing certificates in SideStore.\n\nContinuing means this profile will not be usable for signing apps until a matching signing certificate with private key is imported.", comment: ""), count)),
                    primaryButton: .destructive(Text(NSLocalizedString("Import Anyway", comment: ""))) {
                        commitImport(pending.profile)
                    },
                    secondaryButton: .cancel()
                )
            }
        }
        .alert(isPresented: $showDeleteConfirmation) {
            Alert(
                title: Text(NSLocalizedString("Delete Local Profile?", comment: "")),
                message: Text(String(format: NSLocalizedString("Are you sure you want to delete '%@' from local storage? Any apps assigned to this profile will revert to default.", comment: ""), profileToDelete?.name ?? NSLocalizedString("this profile", comment: ""))),
                primaryButton: .destructive(Text(NSLocalizedString("Delete", comment: ""))) {
                    if let target = profileToDelete {
                        Task {
                            await viewModel.deleteProfile(target, alsoDeleteFromPortal: false)
                        }
                    }
                },
                secondaryButton: .cancel()
            )
        }
        .alert(NSLocalizedString("Delete Portal Profile?", comment: ""), isPresented: $showPortalDeleteConfirmation) {
            SwiftUI.Button(NSLocalizedString("Delete from Portal & Locally", comment: ""), role: .destructive) {
                if let target = profileToDelete {
                    Task {
                        await viewModel.deleteProfile(target, alsoDeleteFromPortal: true)
                    }
                }
            }
            SwiftUI.Button(NSLocalizedString("Delete Locally Only", comment: "")) {
                if let target = profileToDelete {
                    Task {
                        await viewModel.deleteProfile(target, alsoDeleteFromPortal: false)
                    }
                }
            }
            SwiftUI.Button(NSLocalizedString("Cancel", comment: ""), role: .cancel) {}
        } message: {
            Text(String(format: NSLocalizedString("'%@' exists on the Apple Developer Portal. Do you want to delete it from Apple's servers as well, or only delete the local cache?", comment: ""), profileToDelete?.name ?? NSLocalizedString("This profile", comment: "")))
        }
        .alert(NSLocalizedString("Error", comment: ""), isPresented: $viewModel.showErrorAlert) {
            SwiftUI.Button(NSLocalizedString("OK", comment: ""), role: .cancel) { viewModel.errorMessage = nil }
        } message: {
            Text(viewModel.errorMessage ?? NSLocalizedString("An unknown error occurred.", comment: ""))
        }
        .onChange(of: navigateToPortalProfiles) { isActive in
            if !isActive {
                viewModel.loadProfiles(isPullToRefresh: true)
            }
        }
        .background(
            NavigationLink(
                destination: ProfilesListView(viewModel: devServicesViewModel, presentingViewController: presentingViewController),
                isActive: $navigateToPortalProfiles
            ) {
                EmptyView()
            }
            .hidden()
        )
    }

    private func handleFileSelected(at url: URL) {
        do {
            let data = try Data(contentsOf: url)
            let profile = try ALTProvisioningProfile(data: data)
            let analysis = ProfileManager.shared.analyzeCertificates(for: profile)
            self.pendingImport = PendingProfileImport(profile: profile, analysis: analysis)
        } catch {
            viewModel.showToast(String(format: NSLocalizedString("Invalid provisioning profile: %@", comment: ""), error.localizedDescription))
        }
    }

    private func commitImport(_ profile: ALTProvisioningProfile) {
        do {
            _ = try ProfileManager.shared.importProfile(data: profile.data)
            viewModel.loadProfiles(isPullToRefresh: false)
            viewModel.showToast(String(format: NSLocalizedString("Imported '%@' successfully", comment: ""), profile.name))
        } catch {
            viewModel.showToast(String(format: NSLocalizedString("Failed to import profile: %@", comment: ""), error.localizedDescription))
        }
    }

    private func promptDelete(_ profile: ALTProvisioningProfile) {
        profileToDelete = profile
        if viewModel.isRemoteProfile(profile) {
            showPortalDeleteConfirmation = true
        } else {
            showDeleteConfirmation = true
        }
    }

    private func importProfileAction() {
        #if !os(tvOS)
        showFileImporter = true
        #else
        guard let topVC = presentingViewController ?? UIApplication.shared.topViewController() else { return }
        TVWebFileTransferManager.shared.startImport(
            acceptedExtensions: ["mobileprovision"],
            title: "Import Provisioning Profile",
            presentingVC: topVC
        ) { fileURL in
            guard let fileURL = fileURL else { return }
            handleFileSelected(at: fileURL)
        }
        #endif
    }

    private func shareProfile(_ profile: ALTProvisioningProfile) {
        let fileURL = ProfileManager.shared.profileURL(for: profile.uuid)
        guard FileManager.default.fileExists(atPath: fileURL.path) else { return }
        #if !os(tvOS)
        profileToShareURL = fileURL
        #else
        guard let topVC = presentingViewController ?? UIApplication.shared.topViewController() else { return }
        TVWebFileTransferManager.shared.startExport(
            fileURL: fileURL,
            title: "Export Provisioning Profile",
            presentingVC: topVC,
            completion: nil
        )
        #endif
    }

    private func formatDate(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.dateStyle = .short
        formatter.timeStyle = .none
        return formatter.string(from: date)
    }
}

private struct ProfileManagementRowView: View {
    let profile: ALTProvisioningProfile
    let isRemote: Bool
    let formatDate: (Date) -> String

    private var isExpired: Bool {
        profile.expirationDate < Date()
    }

    private var matchingCert: ALTCertificate? {
        ProfileManager.shared.getMatchingCertificate(for: profile)
    }

    private var assignedApps: [String] {
        ProfileManager.shared.getAppsUsingProfile(uuid: profile.uuid)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack {
                Text(profile.name)
                    .font(.headline)
                Spacer()
                if isRemote {
                    HStack(spacing: 3) {
                        Image(systemName: "cloud.fill")
                            .font(.system(size: 8))
                        Text(NSLocalizedString("Portal", comment: ""))
                            .fontWeight(.medium)
                    }
                    .font(.caption2)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(Color.blue.opacity(0.15))
                    .foregroundColor(.blue)
                    .cornerRadius(6)
                } else {
                    HStack(spacing: 3) {
                        Image(systemName: "internaldrive")
                            .font(.system(size: 8))
                        Text(NSLocalizedString("Local", comment: ""))
                            .fontWeight(.medium)
                    }
                    .font(.caption2)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(Color.secondary.opacity(0.15))
                    .foregroundColor(.secondary)
                    .cornerRadius(6)
                }

                if isExpired {
                    Text(NSLocalizedString("Expired", comment: ""))
                        .font(.caption2)
                        .fontWeight(.medium)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(Color.red.opacity(0.15))
                        .foregroundColor(.red)
                        .cornerRadius(6)
                } else if matchingCert != nil {
                    Text(NSLocalizedString("Ready", comment: ""))
                        .font(.caption2)
                        .fontWeight(.medium)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(Color.green.opacity(0.15))
                        .foregroundColor(.green)
                        .cornerRadius(6)
                } else {
                    Text(NSLocalizedString("No Key", comment: ""))
                        .font(.caption2)
                        .fontWeight(.medium)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(Color.orange.opacity(0.15))
                        .foregroundColor(.orange)
                        .cornerRadius(6)
                }
                Text(String(format: NSLocalizedString("Expires: %@", comment: ""), formatDate(profile.expirationDate)))
                    .font(.caption)
                    .foregroundColor(isExpired ? .red : .secondary)
            }

            HStack {
                Text(profile.bundleIdentifier)
                    .font(.subheadline)
                    .foregroundColor(.secondary)
                Spacer()
                Text(profile.teamName)
                    .font(.caption2)
                    .foregroundColor(.secondary)
            }

            if let cert = matchingCert {
                HStack(spacing: 4) {
                    Image(systemName: "key.fill")
                        .font(.system(size: 9))
                        .foregroundColor(.secondary)
                    Text(String(format: NSLocalizedString("Signer: %@", comment: ""), cert.name))
                        .font(.system(size: 10))
                        .foregroundColor(.secondary)
                        .lineLimit(1)
                }
            }

            if !assignedApps.isEmpty {
                HStack(spacing: 4) {
                    Image(systemName: "app.badge.checkmark")
                        .font(.system(size: 9))
                        .foregroundColor(.blue)
                    Text(String(format: NSLocalizedString("Assigned: %@", comment: ""), assignedApps.joined(separator: ", ")))
                        .font(.system(size: 10))
                        .foregroundColor(.blue)
                        .lineLimit(1)
                }
            }
        }
        .padding(.vertical, 2)
    }
}
