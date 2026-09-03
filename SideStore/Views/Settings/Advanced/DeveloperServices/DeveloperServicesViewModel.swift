//
//  DeveloperServicesViewModel.swift
//  SideStore
//
//  Created by Magesh K on 2/9/26.
//  Copyright © 2026 SideStore. All rights reserved.
//

import SwiftUI
import SideSign

@MainActor
class DeveloperServicesViewModel: ObservableObject {
    @Published var appIDs: [ALTAppID] = []
    @Published var profiles: [ALTProvisioningProfile] = []
    @Published var appGroups: [ALTAppGroup] = []
    @Published var devices: [ALTDevice] = []

    @Published var isLoading = false
    @Published var isActionLoading = false
    @Published var errorMessage: String? = nil {
        didSet { showErrorAlert = errorMessage != nil }
    }
    @Published var showErrorAlert = false

    @Published var toastMessage: String = ""
    @Published var showToast = false

    var session: ALTAppleAPISession?
    var team: ALTTeam?

    var isPaidAccount: Bool {
        guard let team = self.team else { return false }
        return team.type != .free && team.type != .unknown
    }

    func showToastMessage(_ message: String) {
        self.toastMessage = message
        self.showToast = true
    }

    private func ensureAuthentication(presentingViewController: UIViewController? = nil) async throws -> (ALTTeam, ALTAppleAPISession) {
        if let team = self.team, let session = self.session {
            return (team, session)
        }
        guard AuthManager.shared.isAuthenticated else {
            throw OperationError.notAuthenticated
        }
        let authResult = try await AuthManager.shared.authenticate(
            presentingViewController: presentingViewController,
            skipDeviceRegistration: true,
            skipCertificateProvisioning: true
        )
        self.team = authResult.team
        self.session = authResult.session
        return (authResult.team, authResult.session)
    }

    func loadAll(presentingViewController: UIViewController? = nil, isPullToRefresh: Bool = false) {
        self.isLoading = true
        self.errorMessage = nil

        Task {
            defer { self.isLoading = false }
            do {
                let (team, session) = try await self.ensureAuthentication(presentingViewController: presentingViewController)
                async let fetchedAppIDs = DeveloperPortalService.shared.fetchAppIDs(team: team, session: session)
                async let fetchedProfiles = DeveloperPortalService.shared.fetchProvisioningProfiles(team: team, session: session)
                async let fetchedGroups = DeveloperPortalService.shared.fetchAppGroups(team: team, session: session)
                async let fetchedDevices = DeveloperPortalService.shared.fetchDevices(for: team, types: .all, session: session)

                let (appIDs, profiles, groups, devices) = try await (fetchedAppIDs, fetchedProfiles, fetchedGroups, fetchedDevices)
                self.appIDs = appIDs.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
                self.profiles = profiles.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
                self.appGroups = groups.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
                self.devices = devices.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
            } catch {
                if !(error is CancellationError) {
                    self.errorMessage = error.localizedDescription
                }
            }
        }
    }

    func fetchAppIDs(presentingViewController: UIViewController? = nil) async {
        do {
            let (team, session) = try await self.ensureAuthentication(presentingViewController: presentingViewController)
            let ids = try await DeveloperPortalService.shared.fetchAppIDs(team: team, session: session)
            self.appIDs = ids.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
        } catch {
            if !(error is CancellationError) {
                self.errorMessage = error.localizedDescription
            }
        }
    }

    func createAppID(name: String, bundleIdentifier: String, presentingViewController: UIViewController? = nil) async -> Bool {
        self.isActionLoading = true
        defer { self.isActionLoading = false }
        do {
            let (team, session) = try await self.ensureAuthentication(presentingViewController: presentingViewController)
            let newAppID = try await DeveloperPortalService.shared.addAppID(name: name, bundleIdentifier: bundleIdentifier, team: team, session: session)
            self.appIDs.append(newAppID)
            self.appIDs.sort { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
            self.showToastMessage(String(format: NSLocalizedString("Registered App ID '%@'", comment: ""), newAppID.name))
            return true
        } catch {
            self.errorMessage = error.localizedDescription
            return false
        }
    }

    func deleteAppID(_ appID: ALTAppID, presentingViewController: UIViewController? = nil) async -> Bool {
        self.isActionLoading = true
        defer { self.isActionLoading = false }
        do {
            let (team, session) = try await self.ensureAuthentication(presentingViewController: presentingViewController)
            _ = try await DeveloperPortalService.shared.deleteAppID(appID, team: team, session: session)
            self.appIDs.removeAll { $0.identifier == appID.identifier }
            self.showToastMessage(String(format: NSLocalizedString("Deleted App ID '%@'", comment: ""), appID.name))
            return true
        } catch {
            self.errorMessage = error.localizedDescription
            return false
        }
    }

    func updateAppGroups(for appID: ALTAppID, to selectedGroups: [ALTAppGroup], presentingViewController: UIViewController? = nil) async -> Bool {
        self.isActionLoading = true
        defer { self.isActionLoading = false }
        do {
            let (team, session) = try await self.ensureAuthentication(presentingViewController: presentingViewController)
            let updated = try await DeveloperPortalService.shared.assignAppID(appID, to: selectedGroups, team: team, session: session)
            if let idx = self.appIDs.firstIndex(where: { $0.identifier == appID.identifier }) {
                self.appIDs[idx] = updated
            }
            self.showToastMessage(String(format: NSLocalizedString("Updated App Groups for '%@'", comment: ""), appID.name))
            return true
        } catch {
            self.errorMessage = error.localizedDescription
            return false
        }
    }

    func fetchProfiles(presentingViewController: UIViewController? = nil) async {
        do {
            let (team, session) = try await self.ensureAuthentication(presentingViewController: presentingViewController)
            let profs = try await DeveloperPortalService.shared.fetchProvisioningProfiles(team: team, session: session)
            self.profiles = profs.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
        } catch {
            if !(error is CancellationError) {
                self.errorMessage = error.localizedDescription
            }
        }
    }

    func downloadProfile(for appID: ALTAppID, presentingViewController: UIViewController? = nil) async -> Bool {
        self.isActionLoading = true
        defer { self.isActionLoading = false }
        do {
            let (team, session) = try await self.ensureAuthentication(presentingViewController: presentingViewController)
            let profile = try await DeveloperPortalService.shared.downloadProvisioningProfile(for: appID, deviceType: .iphone, team: team, session: session)
            if let idx = self.profiles.firstIndex(where: { $0.uuid == profile.uuid || $0.bundleIdentifier == profile.bundleIdentifier }) {
                self.profiles[idx] = profile
            } else {
                self.profiles.append(profile)
            }
            self.profiles.sort { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
            self.showToastMessage(String(format: NSLocalizedString("Downloaded profile for '%@'", comment: ""), appID.name))
            return true
        } catch {
            self.errorMessage = error.localizedDescription
            return false
        }
    }

    func deleteProfile(_ profile: ALTProvisioningProfile, presentingViewController: UIViewController? = nil) async -> Bool {
        self.isActionLoading = true
        defer { self.isActionLoading = false }
        do {
            let (team, session) = try await self.ensureAuthentication(presentingViewController: presentingViewController)
            _ = try await DeveloperPortalService.shared.deleteProvisioningProfile(profile, team: team, session: session)
            self.profiles.removeAll { $0.uuid == profile.uuid }
            self.showToastMessage(String(format: NSLocalizedString("Deleted profile '%@'", comment: ""), profile.name))
            return true
        } catch {
            self.errorMessage = error.localizedDescription
            return false
        }
    }

    func deleteAllProfiles(presentingViewController: UIViewController? = nil) async -> (deletedCount: Int, failedCount: Int) {
        self.isActionLoading = true
        defer { self.isActionLoading = false }
        do {
            let (team, session) = try await self.ensureAuthentication(presentingViewController: presentingViewController)
            var deleted = 0
            var failed = 0
            for profile in self.profiles {
                do {
                    _ = try await DeveloperPortalService.shared.deleteProvisioningProfile(profile, team: team, session: session)
                    deleted += 1
                } catch {
                    failed += 1
                }
            }
            await self.fetchProfiles(presentingViewController: presentingViewController)
            if failed > 0 {
                self.showToastMessage(String(format: NSLocalizedString("Purged %d profile(s) (%d failed)", comment: ""), deleted, failed))
            } else {
                self.showToastMessage(String(format: NSLocalizedString("Purged %d profile(s)", comment: ""), deleted))
            }
            return (deleted, failed)
        } catch {
            self.errorMessage = error.localizedDescription
            return (0, 0)
        }
    }

    func fetchAppGroups(presentingViewController: UIViewController? = nil) async {
        do {
            let (team, session) = try await self.ensureAuthentication(presentingViewController: presentingViewController)
            let groups = try await DeveloperPortalService.shared.fetchAppGroups(team: team, session: session)
            self.appGroups = groups.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
        } catch {
            if !(error is CancellationError) {
                self.errorMessage = error.localizedDescription
            }
        }
    }

    func createAppGroup(name: String, groupIdentifier: String, presentingViewController: UIViewController? = nil) async -> Bool {
        self.isActionLoading = true
        defer { self.isActionLoading = false }
        do {
            let (team, session) = try await self.ensureAuthentication(presentingViewController: presentingViewController)
            let newGroup = try await DeveloperPortalService.shared.addAppGroup(name: name, groupIdentifier: groupIdentifier, team: team, session: session)
            self.appGroups.append(newGroup)
            self.appGroups.sort { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
            self.showToastMessage(String(format: NSLocalizedString("Created App Group '%@'", comment: ""), newGroup.name))
            return true
        } catch {
            self.errorMessage = error.localizedDescription
            return false
        }
    }

    func deleteAppGroup(_ group: ALTAppGroup, presentingViewController: UIViewController? = nil) async -> Bool {
        self.isActionLoading = true
        defer { self.isActionLoading = false }
        do {
            let (team, session) = try await self.ensureAuthentication(presentingViewController: presentingViewController)
            _ = try await DeveloperPortalService.shared.deleteAppGroup(group, team: team, session: session)
            self.appGroups.removeAll { $0.identifier == group.identifier || $0.groupID == group.groupID }
            self.showToastMessage(String(format: NSLocalizedString("Deleted App Group '%@'", comment: ""), group.name))
            return true
        } catch {
            self.errorMessage = error.localizedDescription
            return false
        }
    }

    func updateAppGroup(_ group: ALTAppGroup, newName: String, presentingViewController: UIViewController? = nil) async -> Bool {
        self.isActionLoading = true
        defer { self.isActionLoading = false }
        do {
            let (team, session) = try await self.ensureAuthentication(presentingViewController: presentingViewController)
            var target = group
            target.name = newName
            let updated = try await DeveloperPortalService.shared.updateAppGroup(target, team: team, session: session)
            if let idx = self.appGroups.firstIndex(where: { $0.identifier == group.identifier || $0.groupID == group.groupID }) {
                self.appGroups[idx] = updated
            }
            self.appGroups.sort { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
            self.showToastMessage(String(format: NSLocalizedString("Updated App Group '%@'", comment: ""), updated.name))
            return true
        } catch {
            self.errorMessage = error.localizedDescription
            return false
        }
    }

    func fetchDevices(presentingViewController: UIViewController? = nil) async {
        do {
            let (team, session) = try await self.ensureAuthentication(presentingViewController: presentingViewController)
            let devs = try await DeveloperPortalService.shared.fetchDevices(for: team, types: .all, session: session)
            self.devices = devs.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
        } catch {
            if !(error is CancellationError) {
                self.errorMessage = error.localizedDescription
            }
        }
    }

    func registerDevice(name: String, identifier: String, type: ALTDeviceType, presentingViewController: UIViewController? = nil) async -> Bool {
        self.isActionLoading = true
        defer { self.isActionLoading = false }
        do {
            let (team, session) = try await self.ensureAuthentication(presentingViewController: presentingViewController)
            let newDev = try await DeveloperPortalService.shared.registerDevice(name: name, identifier: identifier, type: type, team: team, session: session)
            self.devices.append(newDev)
            self.devices.sort { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
            self.showToastMessage(String(format: NSLocalizedString("Registered Device '%@'", comment: ""), newDev.name))
            return true
        } catch {
            self.errorMessage = error.localizedDescription
            return false
        }
    }

    func updateDevice(_ device: ALTDevice, newName: String, presentingViewController: UIViewController? = nil) async -> Bool {
        self.isActionLoading = true
        defer { self.isActionLoading = false }
        do {
            let (team, session) = try await self.ensureAuthentication(presentingViewController: presentingViewController)
            var target = device
            target.name = newName
            let updated = try await DeveloperPortalService.shared.updateDevice(target, team: team, session: session)
            if let idx = self.devices.firstIndex(where: { $0.identifier == device.identifier }) {
                self.devices[idx] = updated
            }
            self.devices.sort { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
            self.showToastMessage(String(format: NSLocalizedString("Renamed Device to '%@'", comment: ""), updated.name))
            return true
        } catch {
            self.errorMessage = error.localizedDescription
            return false
        }
    }

    func disableDevice(_ device: ALTDevice, presentingViewController: UIViewController? = nil) async -> Bool {
        self.isActionLoading = true
        defer { self.isActionLoading = false }
        do {
            let (team, session) = try await self.ensureAuthentication(presentingViewController: presentingViewController)
            let disabled = try await DeveloperPortalService.shared.disableDevice(device, team: team, session: session)
            if let idx = self.devices.firstIndex(where: { $0.identifier == device.identifier }) {
                self.devices[idx] = disabled
            }
            self.showToastMessage(String(format: NSLocalizedString("Disabled Device '%@'", comment: ""), device.name))
            return true
        } catch {
            self.errorMessage = error.localizedDescription
            return false
        }
    }

    func deleteDevice(_ device: ALTDevice, presentingViewController: UIViewController? = nil) async -> Bool {
        self.isActionLoading = true
        defer { self.isActionLoading = false }
        do {
            let (team, session) = try await self.ensureAuthentication(presentingViewController: presentingViewController)
            _ = try await DeveloperPortalService.shared.deleteDevice(device, team: team, session: session)
            self.devices.removeAll { $0.identifier == device.identifier }
            self.showToastMessage(String(format: NSLocalizedString("Deleted Device '%@'", comment: ""), device.name))
            return true
        } catch {
            self.errorMessage = error.localizedDescription
            return false
        }
    }
}
