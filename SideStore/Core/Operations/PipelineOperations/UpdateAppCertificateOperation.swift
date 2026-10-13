//
//  UpdateAppCertificateOperation.swift
//  SideStore
//
//  Created by Magesh K on 1/8/26.
//  Copyright © 2026 SideStore. All rights reserved.
//

@preconcurrency import UIKit
import Foundation
import CoreData
import SideSign

final class UpdateAppCertificateOperation: BasePipelineOperation<InstallAppOperationContext, Void>, @unchecked Sendable {
    
    override func execute(parentProgress: Progress?) async throws {
        let startTime = CFAbsoluteTimeGetCurrent()
        debugLog("[UpdateAppCertificateOperation] execute() started")
        defer {
            let elapsed = CFAbsoluteTimeGetCurrent() - startTime
            debugLog("[UpdateAppCertificateOperation] execute() took: \(String(format: "%.3fs", elapsed))")
        }
        try await super.executePreconditionCheck(parentProgress: parentProgress)
        
        let targetBundleID = self.context.installedApp?.bundleIdentifier ?? self.context.targetBundleIdentifier
        var profileToUse = self.context.overrideProvisioningProfile ?? ProfileManager.shared.getAssignedProfile(for: targetBundleID)
        var didSwitchFromEnterpriseToAppleID = false
        var removedEnterpriseProfileUUID: String? = nil

        if self.context.resignsAppBundle {
            if self.context.overrideProvisioningProfile == nil {
                if let identity = try await self.resolveEnterpriseIdentity() {
                    if profileToUse == nil || EnterpriseSigningManager.shared.isEnterpriseIdentityProfile(profileToUse!) {
                        debugLog("[UpdateAppCertificateOperation] Enterprise signing. Using profile '\(identity.profile.name)' (\(identity.profile.uuid)) for '\(targetBundleID)'")
                        profileToUse = identity.profile
                        self.context.overrideSigningCertificate = identity.certificate
                    }
                    // When switching an app that had no customBundleIdentifier to a wildcard enterprise profile,
                    // ensure any previous team-suffixed resignedBundleIdentifier loaded from cache is cleared.
                    if identity.profile.isWildcard,
                       let installedApp = self.context.installedApp,
                       installedApp.customBundleIdentifier == nil,
                       self.context.customBundleIdentifier == installedApp.resignedBundleIdentifier,
                       installedApp.resignedBundleIdentifier != installedApp.bundleIdentifier {
                        self.context.customBundleIdentifier = nil
                    }
                } else {
                    if let existingProfile = profileToUse,
                       EnterpriseSigningManager.shared.isEnterpriseIdentityProfile(existingProfile) {
                        debugLog("[UpdateAppCertificateOperation] Switching '\(targetBundleID)' from Enterprise profile '\(existingProfile.name)' back to Apple ID signing.")
                        removedEnterpriseProfileUUID = existingProfile.uuid.uuidString
                        profileToUse = nil
                        ProfileManager.shared.setAssignedProfile(nil, for: targetBundleID)
                        didSwitchFromEnterpriseToAppleID = true
                    } else if let serial = self.context.installedApp?.certificateSerialNumber,
                              serial == EnterpriseSigningManager.shared.identitySerialNumber {
                        didSwitchFromEnterpriseToAppleID = true
                    }

                    if didSwitchFromEnterpriseToAppleID {
                        // Clear cached enterprise entitlements so they don't pollute Apple ID portal registration.
                        if !UserDefaults.standard.customizeEntitlements {
                            self.context.customEntitlementsByBundleID.removeAll()
                            self.context.additionalEntitlements.removeAll()
                        }
                        // Remove the old enterprise/wildcard profile from the device if no other app uses it.
                        if let oldUUID = removedEnterpriseProfileUUID {
                            await self.removeDeviceProfileIfUnused(uuidString: oldUUID, excludingBundleID: targetBundleID)
                        }
                    }
                }
            }
        } else if profileToUse == nil, self.context.installedApp?.isEnterpriseSigned == true {
            // Profile-only refresh on an enterprise-signed app whose ProfileManager binding was cleared or external:
            if let customProfile = self.context.installedApp?.customProvisioningProfile {
                profileToUse = customProfile
            } else if let identity = EnterpriseSigningManager.shared.usableIdentity {
                profileToUse = identity.profile
                self.context.overrideSigningCertificate = identity.certificate
            } else if let embeddedProfile = self.loadEmbeddedEnterpriseProfile() {
                profileToUse = embeddedProfile
            } else {
                // Never fall back to the 7-day Apple ID portal flow for a profile-only refresh of an
                // enterprise-signed binary (which would corrupt expirationDate without re-signing the binary).
                throw OperationError.missingProvisioningProfile(
                    reason: NSLocalizedString("Could not find the enterprise provisioning profile for this app. Use Resign or Reinstall to switch to Apple ID signing.", comment: "")
                )
            }
        }

        if let assignedProfile = profileToUse {
            debugLog("[UpdateAppCertificateOperation] Target bundle '\(targetBundleID)' using assigned profile: '\(assignedProfile.name)' (\(assignedProfile.uuid))")
            self.context.overrideProvisioningProfile = assignedProfile

            if self.context.overrideSigningCertificate != nil, EnterpriseSigningManager.shared.usableIdentity?.profile.uuid == assignedProfile.uuid {
                // Certificate already resolved from the enterprise identity above.
            } else if let matchingCert = ProfileManager.shared.getMatchingCertificate(for: assignedProfile) {
                debugLog("[UpdateAppCertificateOperation] Loaded matching certificate '\(matchingCert.serialNumber)' for assigned profile. Setting context.overrideSigningCertificate.")
                self.context.overrideSigningCertificate = matchingCert
            } else if let serialNumber = self.context.installedApp?.certificateSerialNumber,
                      let customCert = CertificateManager.shared.getSignableCertificate(for: serialNumber) {
                self.context.overrideSigningCertificate = customCert
            }
        } else if !didSwitchFromEnterpriseToAppleID,
                  let installedApp = self.context.installedApp,
                  let serialNumber = installedApp.certificateSerialNumber {
            debugLog("[UpdateAppCertificateOperation] InstalledApp '\(installedApp.name)' has custom certificate serial: '\(serialNumber)'")
            if let customCert = CertificateManager.shared.getSignableCertificate(for: serialNumber) {
                debugLog("[UpdateAppCertificateOperation] Loaded custom certificate '\(customCert.serialNumber)' for app '\(installedApp.name)'. Setting context.overrideSigningCertificate.")
                self.context.overrideSigningCertificate = customCert
            } else {
                debugLog("[UpdateAppCertificateOperation] WARNING: Signable certificate with serial '\(serialNumber)' not found for app '\(installedApp.name)'.")
            }
        }
        
        self.setProgress(100)
    }

    private func loadEmbeddedEnterpriseProfile() -> ALTProvisioningProfile? {
        guard let installedApp = self.context.installedApp else { return nil }
        let candidates: [URL] = [
            installedApp.directoryURL.appendingPathComponent("App.app").appendingPathComponent("embedded.mobileprovision"),
            installedApp.fileURL.appendingPathComponent("embedded.mobileprovision"),
            Bundle.main.bundleURL.appendingPathComponent("embedded.mobileprovision")
        ]
        for url in candidates where FileManager.default.fileExists(atPath: url.path) {
            if EnterpriseSigningDetector.isEnterpriseProfile(at: url),
               let profile = try? ALTProvisioningProfile(url: url) {
                return profile
            }
        }
        return nil
    }

    private func removeDeviceProfileIfUnused(uuidString: String, excludingBundleID: String) async {
        // Keep the profile on device if Enterprise mode is still globally active with this profile.
        if EnterpriseSigningManager.shared.preference != .appleID,
           EnterpriseSigningManager.shared.profileUUID?.caseInsensitiveCompare(uuidString) == .orderedSame {
            return
        }
        let stillUsedByOtherApp = self.context.dbBackgroundContext.performAndWait { () -> Bool in
            let apps = InstalledApp.fetchActiveApps(in: self.context.dbBackgroundContext)
            return apps.contains { app in
                guard app.bundleIdentifier != excludingBundleID else { return false }
                if let assigned = ProfileManager.shared.getAssignedProfile(for: app.bundleIdentifier),
                   assigned.uuid.uuidString.caseInsensitiveCompare(uuidString) == .orderedSame {
                    return true
                }
                if let customProfile = app.customProvisioningProfile,
                   customProfile.uuid.uuidString.caseInsensitiveCompare(uuidString) == .orderedSame {
                    return true
                }
                return false
            }
        }
        guard !stillUsedByOtherApp else { return }
        debugLog("[UpdateAppCertificateOperation] Removing unused enterprise profile \(uuidString) from device.")
        try? await removeProvisioningProfile(uuidString)
    }

    /// Enterprise: picks the enterprise identity per the user's signing preference, asking when set to
    /// "Ask Every Time" and both an Apple ID and an enterprise identity are available.
    private func resolveEnterpriseIdentity() async throws -> EnterpriseSigningIdentity? {
        let manager = EnterpriseSigningManager.shared
        guard let identity = manager.usableIdentity else { return nil }

        // Normally decided once per install group by PipelineRunner before the pipeline starts.
        switch self.context.sharedContext.signingChoice {
        case .enterprise?: return identity
        case .appleID?: return nil
        case .cancel?: throw OperationError.cancelled
        case nil: break
        }

        switch manager.preference {
        case .appleID:
            return nil
        case .enterprise:
            return identity
        case .ask:
            guard AuthManager.shared.isAuthenticated else { return identity }
            let appName = self.context.targetAppBundle?.name ?? self.context.targetBundleIdentifier
            let choice = await self.context.handler.signingChoiceHandler.chooseSigningCertificate(
                appName: appName,
                enterpriseTeamName: identity.team.name
            )
            switch choice {
            case .appleID: return nil
            case .enterprise: return identity
            case .cancel: throw OperationError.cancelled
            }
        }
    }
}
