//
//  OnDeviceAnisetteManager.swift
//  SideStore
//
//  Created by Magesh K on 18/08/26.
//  Copyright © 2026 SideStore. All rights reserved.
//

import Foundation
import AnisetteKit
import SideSign

public actor OnDeviceAnisetteManager {
    public static let shared = OnDeviceAnisetteManager()

    private let provider: AnisetteDataProvider

    private init() {
        let baseDir: URL?
        if let sharedDir = FileManager.default.altstoreSharedDirectory {
            baseDir = sharedDir.appendingPathComponent(AppConstants.Anisette.hiddenBaseDirectoryName, isDirectory: true)
        } else if let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first {
            baseDir = appSupport
                .appendingPathComponent(AppConstants.Anisette.appSupportSubdirectory, isDirectory: true)
                .appendingPathComponent(AppConstants.Anisette.hiddenBaseDirectoryName, isDirectory: true)
        } else {
            baseDir = nil
        }
        self.provider = AnisetteDataProvider(baseDirectory: baseDir)
    }

    public nonisolated var baseAnisetteDirectory: URL? {
        provider.baseAnisetteDirectory
    }

    public nonisolated var librariesDirectory: URL? {
        provider.libsDir
    }

    public nonisolated var provisioningDirectory: URL? {
        provider.provisioningDir
    }

    public func isReady() async -> Bool {
        await provider.isReady()
    }

    public func fetchAnisetteData() async throws -> ALTAnisetteData {
        debugLog("[OnDeviceAnisetteManager] [Fetch] Fetching on-device Anisette headers...")

        let identifierUUID = resolveDeviceIdentifier()

        var existingAdiPbData: Data? = nil
        if let base64Blob = AnisetteDataManager.shared.anisetteAdiBlob,
           let decoded = Data(base64Encoded: base64Blob, options: .ignoreUnknownCharacters),
           !decoded.isEmpty {
            existingAdiPbData = decoded
            debugLog("[OnDeviceAnisetteManager] [Fetch] Reusing existing adi.pb from Keychain (\(decoded.count) bytes)")
        } else {
            debugLog("[OnDeviceAnisetteManager] [Fetch] No existing adi.pb in Keychain -> local in-memory provisioning will be performed")
        }

        let config = await AnisetteConfigManager.shared.loadConfig()
        let clientInfo = config.clientInfo.isEmpty ? LocalAnisetteProvider.defaultClientInfo : config.clientInfo
        let resolvedLocale = config.customLocale != nil ? Locale(identifier: config.customLocale!) : .current
        let resolvedTimeZone = config.customTimeZone != nil ? (TimeZone(identifier: config.customTimeZone!) ?? .current) : .current

        let sourceURLString = UserDefaults.standard.menuAnisetteList.isEmpty ? AnisetteServersManager.defaultSource : UserDefaults.standard.menuAnisetteList
        let sourceURL = URL(string: sourceURLString) ?? URL(string: AppConstants.Anisette.defaultODAMetadataURL)!
        let fallbackURL = URL(string: AppConstants.Anisette.defaultODAMetadataURL)

        let mode = AnisetteMode.remoteODA(sourceURL: sourceURL, fallbackURL: fallbackURL)

        let (anisetteData, newAdiPb) = try await provider.fetchAnisetteData(
            mode: mode,
            identifier: identifierUUID,
            existingAdiBlob: existingAdiPbData,
            clientInfo: clientInfo,
            customLocalUserID: config.customLocalUserID,
            customDeviceID: config.customDeviceID,
            customLocale: resolvedLocale,
            customTimeZone: resolvedTimeZone
        )

        if let freshBlob = newAdiPb {
            AnisetteDataManager.shared.anisetteAdiBlob = freshBlob.base64EncodedString()
            debugLog("[OnDeviceAnisetteManager] [Fetch] Fresh local provisioning completed -> saved new adi.pb (\(freshBlob.count) bytes) to Keychain")
        }

        debugLog("[OnDeviceAnisetteManager] [Fetch] SUCCESS: AnisetteData generated successfully.")
        return anisetteData
    }

    private func resolveDeviceIdentifier() -> UUID {
        if let storedId = AnisetteDataManager.shared.anisetteIdentifier, !storedId.isEmpty {
            if let parsed = UUID(uuidString: storedId) {
                debugLog("[OnDeviceAnisetteManager] [Fetch] Using existing device UUID: \(parsed.uuidString)")
                return parsed
            }
            if let data = Data(base64Encoded: storedId), data.count == 16 {
                let uuid = data.withUnsafeBytes { UUID(uuid: $0.load(as: uuid_t.self)) }
                debugLog("[OnDeviceAnisetteManager] [Fetch] Using existing base64-encoded device UUID: \(uuid.uuidString)")
                return uuid
            }
        }
        let generated = UUID()
        AnisetteDataManager.shared.anisetteIdentifier = generated.uuidString
        debugLog("[OnDeviceAnisetteManager] [Fetch] Generated new device UUID: \(generated.uuidString)")
        return generated
    }
}
