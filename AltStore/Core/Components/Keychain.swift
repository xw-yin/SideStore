//
//  Keychain.swift
//  AltStore
//
//  Created by Riley Testut on 6/4/19.
//  Copyright © 2019 Riley Testut. All rights reserved.
//

import Foundation
private import KeychainAccess
import SideSign
import Security

@propertyWrapper
public struct KeychainItem<Value>
{
    public let key: String
    
    public var wrappedValue: Value? {
        get {
            switch Value.self
            {
            case is Data.Type: return try? Keychain.shared.keychain.getData(self.key) as? Value
            case is String.Type: return try? Keychain.shared.keychain.getString(self.key) as? Value
            default: return nil
            }
        }
        set {
            switch Value.self
            {
            case is Data.Type: Keychain.shared.keychain[data: self.key] = newValue as? Data
            case is String.Type: Keychain.shared.keychain[self.key] = newValue as? String
            default: break
            }
        }
    }
    
    public init(key: String)
    {
        self.key = key
    }
}

public class Keychain
{
    public static let shared = Keychain()
    
    fileprivate let keychain: KeychainAccess.Keychain = {
        var keychain = KeychainAccess.Keychain(service: Bundle.Info.appbundleIdentifier)
            .accessibility(.afterFirstUnlock)
            .synchronizable(true)
        // LiveContainer+SideStore: the "Refresh All Apps" shortcut launches SideStore inside
        // LiveProcess.appex, whose default keychain access group differs from the main app
        // process where the user signed in. Point the appex at the host app's keychain group
        // so both share the same login state instead of reporting "not signed in".
        if let hostGroup = Keychain.liveContainerHostKeychainGroup {
            keychain = keychain.accessGroup(hostGroup)
        }
        return keychain
    }()
    
    @KeychainItem(key: "appleIDEmailAddress")
    public var appleIDEmailAddress: String?
    
    @KeychainItem(key: "appleIDPassword")
    public var appleIDPassword: String?
    
    @KeychainItem(key: "appleIDAdsid")
    public var appleIDAdsid: String?
    
    @KeychainItem(key: "appleIDXcodeToken")
    public var appleIDXcodeToken: String?
    
    @KeychainItem(key: "signingCertificate")
    public var signingCertificate: Data?
    
    @KeychainItem(key: "signingCertificatePassword")
    public var signingCertificatePassword: String?
    
    // TODO: mahee96: remove legacy keys in later versions after 0.6.4 coz by now our migrations should be effectively moved all
    // Legacy
    @KeychainItem(key: "signingCertificatePrivateKey")
    public var signingCertificatePrivateKey: Data?
    
    // TODO: mahee96: remove legacy keys in later versions after 0.6.4 coz by now our migrations should be effectively moved all
    // Legacy
    @KeychainItem(key: "signingCertificateSerialNumber")
    public var signingCertificateSerialNumber: String?
    
    @KeychainItem(key: "identifier")
    public var identifier: String?
    
    @KeychainItem(key: "adiPb")
    public var adiPb: String?

    @KeychainItem(key: "deviceUDID")
    public var deviceUDID: String?

    // MARK: - Dynamic Imported Certificates Storage

    public subscript(certificateSerial serial: String) -> Data? {
        get { try? self.keychain.getData("importedCert_" + serial) }
        set {
            if let data = newValue {
                try? self.keychain.set(data, key: "importedCert_" + serial)
            } else {
                try? self.keychain.remove("importedCert_" + serial)
            }
        }
    }
    
    private init()
    {
        self.migrateLegacyKeychainItems()
    }
    
    private func migrateLegacyKeychainItems()
    {
        let signingCertificateKey   = "signingCertificate"
        let privateKeyKey           = "signingCertificatePrivateKey"
        let serialNumberKey         = "signingCertificateSerialNumber"
        
        // 1. Check if signingCertificate contains data and is NOT a PKCS#12 archive
        guard let certData = try? self.keychain.getData(signingCertificateKey), !certData.isPKCS12 else { return }
        
        // 2. Check if we have the private key
        guard let privateKey = try? self.keychain.getData(privateKeyKey) else { return }
        
        // 3. Load the raw certificate and pair with private key
        guard let x509 = ALTX509Certificate(data: certData) else { return }
        let cert = ALTCertificate(x509: x509, privateKey: privateKey)
        
        // 4. Create PKCS12 data structure
        do {
            let p12Data = try cert.unencryptedP12Data()
            // 5. Store the new PKCS12 format in signingCertificate slot
            try self.keychain.set(p12Data, key: signingCertificateKey)
            try self.keychain.set("", key: "signingCertificatePassword")
            
            // 6. Clear legacy keys
            try self.keychain.remove(privateKeyKey)
            try self.keychain.remove(serialNumberKey)
            
            debugLog("[Keychain] Successfully migrated legacy certificate and private key to PKCS12 format and cleared legacy keys.")
        } catch {
            debugLog("[Keychain] Failed to migrate legacy certificate to PKCS12 format: \(error)")
        }
    }
    
    public func clearCertificates()
    {
        // Legacy
        self.signingCertificatePrivateKey = nil
        self.signingCertificateSerialNumber = nil

        self.signingCertificate = nil
        self.signingCertificatePassword = nil
        
        debugLog("[Keychain] Cleared signing certificate & private key from Keychain.")
    }
    
    public func clearSignInInfo(keepAnisetteData: Bool = true)
    {
        debugLog("[Keychain] Clearing sign-in info from Keychain (keepAnisetteData: \(keepAnisetteData))...")
        
        self.appleIDEmailAddress = nil
        self.appleIDPassword = nil
        self.appleIDAdsid = nil
        self.appleIDXcodeToken = nil
        debugLog("[Keychain] Cleared Apple ID credentials & tokens (email, password, adsid, xcodeToken).")

        if !keepAnisetteData {
            self.adiPb = nil
            debugLog("[Keychain] Cleared Anisette ADI data (adiPb).")
        } else {
            debugLog("[Keychain] Preserved Anisette ADI data (adiPb).")
        }
        
        debugLog("[Keychain] Cleared sign-in info from Keychain.")
    }

    public func clearAll()
    {
        debugLog("[Keychain] Clearing all Keychain items related to this instance...")
        try? self.keychain.removeAll()
        debugLog("[Keychain] All Keychain items cleared.")
    }
}

// MARK: - LiveContainer Host Keychain Sharing

extension Keychain
{
    /// Returns the LiveContainer host app's keychain access group when SideStore is running
    /// inside LiveProcess.appex (the "Refresh All Apps" shortcut flow), nil otherwise.
    ///
    /// The interactive SideStore runs in the main app process and stores the Apple ID login
    /// under the main app's default keychain group. The shortcut flow runs in the appex
    /// process, whose default group is different, so without this it cannot see the login
    /// and refresh fails with "not signed in". Needs proper testing on-device: the appex
    /// must be signed with "Use Main Profile" so its entitlements grant the host's group.
    fileprivate static var liveContainerHostKeychainGroup: String?
    {
        // 1. Only when hosted by LiveProcess.appex.
        let appexURL = Bundle.main.bundleURL
        guard appexURL.path.contains("LiveProcess.appex") else { return nil }

        // 2. Host app bundle ID, read from disk (robust against user re-signed bundle IDs).
        let hostAppURL = appexURL.deletingLastPathComponent().deletingLastPathComponent()
        guard let hostBundleID = Bundle(url: hostAppURL)?.bundleIdentifier, !hostBundleID.isEmpty else { return nil }

        // 3. Team ID from our own application-identifier entitlement ("TEAMID.bundle.id").
        guard let task = SecTaskCreateFromSelf(nil) else { return nil }
        var error: Unmanaged<CFError>?
        guard let applicationID = SecTaskCopyValueForEntitlement(task, "application-identifier" as CFString, &error) as? String else { return nil }
        let teamID = applicationID.split(separator: ".", maxSplits: 1).first.map(String.init) ?? ""
        guard !teamID.isEmpty else { return nil }

        let group = "\(teamID).\(hostBundleID)"

        // 4. Only use it when our entitlements actually grant this group.
        guard let allowedGroups = SecTaskCopyValueForEntitlement(task, "keychain-access-groups" as CFString, &error) as? [String],
              allowedGroups.contains(group) else { return nil }

        return group
    }
}
