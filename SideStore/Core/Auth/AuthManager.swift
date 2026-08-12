//
//  AuthManager.swift
//  SideStore
//
//  Created by Magesh K on 1/8/26.
//  Copyright © 2026 SideStore. All rights reserved.
//

@preconcurrency import UIKit
import Foundation
@preconcurrency import AltSign
@preconcurrency import AltStoreCore

public final class AuthManager: @unchecked Sendable {
    public static let shared = AuthManager()
    
    private init() {}
    
    public var team: ALTTeam?
    public var session: ALTAppleAPISession?

    public var isAuthenticated: Bool {
        let hasEmail = Keychain.shared.appleIDEmailAddress != nil
        let hasPassword = Keychain.shared.appleIDPassword != nil
        let hasToken = Keychain.shared.appleIDXcodeToken != nil
        return hasEmail && (hasPassword || hasToken)
    }
    
    public var currentAppleID: String? {
        get { Keychain.shared.appleIDEmailAddress }
        set { Keychain.shared.appleIDEmailAddress = newValue }
    }
    
    public var password: String? {
        get { Keychain.shared.appleIDPassword }
        set { Keychain.shared.appleIDPassword = newValue }
    }
    
    public var adsid: String? {
        get { Keychain.shared.appleIDAdsid }
        set { Keychain.shared.appleIDAdsid = newValue }
    }
    
    public var xcodeToken: String? {
        get { Keychain.shared.appleIDXcodeToken }
        set { Keychain.shared.appleIDXcodeToken = newValue }
    }
    
    public var hasStoredPassword: Bool {
        return Keychain.shared.appleIDPassword != nil
    }
    
    public var hasStoredXcodeToken: Bool {
        return Keychain.shared.appleIDXcodeToken != nil
    }
    
    public func signOut(keepCertificate: Bool = false, keepAnisetteData: Bool = true) {
        self.session = nil
        self.team = nil
        CertificateManager.shared.clearActiveCertificate()
        DatabaseManager.shared.deactivateActiveAccountAndTeam()
        Keychain.shared.reset(keepCertificate: keepCertificate, keepAnisetteData: keepAnisetteData)
    }
    
    @discardableResult
    func authenticate(
        presentingViewController: UIViewController? = nil,
        context: AuthenticatedOperationContext? = nil,
        skipDeviceRegistration: Bool = false,
        skipCertificateProvisioning: Bool = false
    ) async throws -> AuthenticationResult {
        let effectiveContext: AuthenticatedOperationContext
        if let context = context {
            effectiveContext = context
        } else {
            let dbBackgroundContext = DatabaseManager.shared.persistentContainer.newBackgroundContext()
            let authFlowHandler = AuthFlowHandler(presentingViewController: presentingViewController)
            effectiveContext = AuthenticatedOperationContext(
                authenticationHandler: authFlowHandler,
                anisetteServerHandler: authFlowHandler,
                dbBackgroundContext: dbBackgroundContext
            )
        }
        
        let authOperation = try AuthenticationOperation(
            context: effectiveContext,
            skipDeviceRegistration: skipDeviceRegistration,
            skipCertificateProvisioning: skipCertificateProvisioning
        )
        return try await authOperation.execute()
    }
    
    
    // Developer Portal API Operations
    
    public func fetchCertificates(team: ALTTeam, session: ALTAppleAPISession) async throws -> [ALTX509Certificate] {
        return try await DeveloperPortalService.shared.fetchCertificates(team: team, session: session)
    }
    
    public func createCertificate(machineName: String, team: ALTTeam, session: ALTAppleAPISession) async throws -> ALTCertificate {
        return try await DeveloperPortalService.shared.createCertificate(machineName: machineName, team: team, session: session)
    }
    
    public func revokeCertificate(_ certificate: ALTX509Certificate, team: ALTTeam, session: ALTAppleAPISession) async throws -> Bool {
        return try await DeveloperPortalService.shared.revokeCertificate(certificate, team: team, session: session)
    }
    
    public func authenticate(appleID: String, password: String, anisetteData: ALTAnisetteData, xcodeVersion: String, verificationHandler: ((@escaping (String?) -> Void) -> Void)?) async throws -> (ALTAccount, ALTAppleAPISession) {
        return try await DeveloperPortalService.shared.authenticate(appleID: appleID, password: password, anisetteData: anisetteData, xcodeVersion: xcodeVersion, verificationHandler: verificationHandler)
    }
    
    public func authenticateWithToken(adsid: String, xcodeToken: String, anisetteData: ALTAnisetteData, xcodeVersion: String) async throws -> (ALTAccount, ALTAppleAPISession) {
        return try await DeveloperPortalService.shared.authenticateWithToken(adsid: adsid, xcodeToken: xcodeToken, anisetteData: anisetteData, xcodeVersion: xcodeVersion)
    }
    
    @discardableResult
    public func fetchAccount(session: ALTAppleAPISession) async throws -> ALTAccount {
        return try await DeveloperPortalService.shared.fetchAccount(session: session)
    }
    
    public func fetchTeams(for account: ALTAccount, session: ALTAppleAPISession) async throws -> [ALTTeam] {
        return try await DeveloperPortalService.shared.fetchTeams(for: account, session: session)
    }
    
    public func fetchCertificates(for team: ALTTeam, session: ALTAppleAPISession) async throws -> [ALTX509Certificate] {
        return try await DeveloperPortalService.shared.fetchCertificates(team: team, session: session)
    }
    
    public func addCertificate(machineName: String, to team: ALTTeam, session: ALTAppleAPISession) async throws -> ALTCertificate {
        return try await DeveloperPortalService.shared.createCertificate(machineName: machineName, team: team, session: session)
    }
    
    public func revokeCertificate(_ certificate: ALTX509Certificate, for team: ALTTeam, session: ALTAppleAPISession) async throws {
        _ = try await DeveloperPortalService.shared.revokeCertificate(certificate, team: team, session: session)
    }
    
    public func fetchDevices(for team: ALTTeam, types: ALTDeviceType, session: ALTAppleAPISession) async throws -> [ALTDevice] {
        return try await DeveloperPortalService.shared.fetchDevices(for: team, types: types, session: session)
    }
    
    public func registerDevice(name: String, identifier: String, type: ALTDeviceType, team: ALTTeam, session: ALTAppleAPISession) async throws -> ALTDevice {
        return try await DeveloperPortalService.shared.registerDevice(name: name, identifier: identifier, type: type, team: team, session: session)
    }
}

fileprivate extension DatabaseManager {
    //TODO: this is not clean, but for now this should be fine, ie we should later make this proper async instead of blocking
    func deactivateActiveAccountAndTeam() {
        let bgContext = self.persistentContainer.newBackgroundContext()
        bgContext.performAndWait {
            if let account = self.activeAccount(in: bgContext) {
                account.isActiveAccount = false
            }
            if let team = self.activeTeam(in: bgContext) {
                team.isActiveTeam = false
            }
            do {
                try bgContext.save()
            } catch {
                debugLog("[AuthManager] Failed to save CoreData context when deactivating active account and team: \(error)")
            }
        }
        
        self.viewContext.performAndWait {
            self.viewContext.processPendingChanges()
            self.viewContext.refreshAllObjects()
        }
    }
}
