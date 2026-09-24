//
//  PairingFileManager.swift
//  SideStore
//
//  Created by Magesh K on 17/06/26.
//  Copyright © 2026 SideStore. All rights reserved.
//

import Foundation
import UniformTypeIdentifiers
import MinimuxerCommon

public struct PairingFileMetadata: Sendable {
    public let exists: Bool
    public let size: Int64
    public let creationDate: Date?
    public let modificationDate: Date?
}

final class PairingFileManager: NSObject {
    static let shared = PairingFileManager()

    static var supportedContentTypes: [UTType] {
        var types = AppConstants.Pairing.supportedExtensions.compactMap { UTType(filenameExtension: $0) }
        types.append(contentsOf: [.propertyList, .xml])
        return types
    }

    var activeProtocol: PairingProtocol {
        minimuxerPairingProtocol()
    }

    var persistedActiveProtocol: PairingProtocol? {
        get { UserDefaults.standard.activePairingProtocol }
        set { UserDefaults.standard.activePairingProtocol = newValue }
    }

    var preferredProtocol: PairingProtocol? {
        get { UserDefaults.standard.preferredPairingProtocol }
        set { UserDefaults.standard.preferredPairingProtocol = newValue }
    }

    nonisolated func pairingFileURL(for mode: PairingProtocol) -> URL {
        let fileName = mode == .rppairing ? AppConstants.Pairing.remotePairingFileName : AppConstants.Pairing.lockdownPairingFileName
        return FileManager.default.documentsDirectory.appendingPathComponent(fileName)
    }

    nonisolated func hasPairingFile(for mode: PairingProtocol) -> Bool {
        return FileManager.default.fileExists(atPath: pairingFileURL(for: mode).path)
    }

    nonisolated func hasPairingFile() -> Bool {
        guard !UserDefaults.standard.isPairingReset else { return false }
        if let target = preferredProtocol, hasPairingFile(for: target) {
            return true
        }
        if let mode = persistedActiveProtocol, hasPairingFile(for: mode) {
            return true
        }
        return false
    }

    nonisolated func metadata(for mode: PairingProtocol) -> PairingFileMetadata {
        let fileURL = pairingFileURL(for: mode)
        let path = fileURL.path
        let fm = FileManager.default
        guard fm.fileExists(atPath: path) else {
            return PairingFileMetadata(exists: false, size: 0, creationDate: nil, modificationDate: nil)
        }
        let attrs = (try? fm.attributesOfItem(atPath: path)) ?? [:]
        let size = (attrs[.size] as? NSNumber)?.int64Value ?? 0
        let creation = (attrs[.creationDate] as? Date) ?? (attrs[.modificationDate] as? Date)
        let mod = attrs[.modificationDate] as? Date
        return PairingFileMetadata(exists: true, size: size, creationDate: creation, modificationDate: mod)
    }

    nonisolated func fetchPairingFile(for mode: PairingProtocol) -> String? {
        let fileURL = pairingFileURL(for: mode)
        let fm = FileManager.default
        if fm.fileExists(atPath: fileURL.path),
           let contents = try? String(contentsOf: fileURL), !contents.isEmpty 
        {
            return contents
        }
        return nil
    }

    nonisolated func fetchPairingFile(preferred: PairingProtocol? = nil) -> String? {
        guard !UserDefaults.standard.isPairingReset else { return nil }
        let targetPreferred = preferred ?? preferredProtocol
        if let targetPreferred, let contents = fetchPairingFile(for: targetPreferred) {
            return contents
        }
        if let persisted = persistedActiveProtocol {
            return fetchPairingFile(for: persisted)
        }
        // Fork compatibility: fall back to App Group shared container and
        // bundle-embedded pairing files (LiveContainer deployment scenario).
        return AppBootManager.shared.getSavedPairingFile()
    }
    
    @discardableResult
    nonisolated func parse(content: String, preferred: PairingProtocol? = nil) throws -> any PairingFile {
        try PairingFileParser.parse(content: content, preferred: preferred)
    }

    @discardableResult
    func savePairingFile(contents: String, preferred: PairingProtocol? = nil) throws -> any PairingFile {
        let parsed = try parse(content: contents, preferred: preferred)
        let destinationURL = pairingFileURL(for: parsed.mode)
        let fm = FileManager.default
        if fm.fileExists(atPath: destinationURL.path) {
            try? fm.removeItem(at: destinationURL)
        }
        try contents.write(to: destinationURL, atomically: true, encoding: .utf8)
        debugLog("[PairingFile] Saved \(parsed.mode.rawValue) pairing file to: \(destinationURL.path)")

        // Fork: also mirror into the App Group shared container so the
        // LiveContainer host build can find it.
        if let sharedDirectory = fm.altstoreSharedDirectory {
            let sharedPath = sharedDirectory.appendingPathComponent(destinationURL.lastPathComponent)
            do {
                try contents.write(to: sharedPath, atomically: true, encoding: .utf8)
                debugLog("[PairingFile] Successfully copied pairing file to shared container: \(sharedPath.path)")
            } catch {
                debugLog("[PairingFile] Unable to copy pairing file to shared container: \(error)")
            }
        }

        UserDefaults.standard.isPairingReset = false
        return parsed
    }

    func inspectPairingFile(from url: URL) throws -> (content: String, file: any PairingFile) {
        let isSecured = url.startAccessingSecurityScopedResource()
        defer {
            if isSecured {
                url.stopAccessingSecurityScopedResource()
            }
        }
        let data = try Data(contentsOf: url)
        guard let content = String(data: data, encoding: .utf8) ?? String(data: data, encoding: .isoLatin1) else {
            throw CocoaError(.fileReadInapplicableStringEncoding)
        }
        let parsed = try parse(content: content, preferred: nil)
        return (content, parsed)
    }

    func importPairingFile(from url: URL, preferred: PairingProtocol? = nil) throws {
        let (content, _) = try inspectPairingFile(from: url)
        let parsed = try savePairingFile(contents: content, preferred: preferred)
        persistedActiveProtocol = parsed.mode
    }

    // Composite (dual-protocol) pairing files, e.g. exported by iLoader, carry
    // both a Lockdown record and a RemotePairing record in one plist. Returns
    // every protocol the content fully satisfies; count > 1 means composite.
    // Note: the key sets below must stay in sync with the required keys in
    // minimuxer's PairingFile.swift (RPPairingFile / LockdownPairingFile).
    nonisolated func compositeModes(in content: String) -> [PairingProtocol] {
        var modes: [PairingProtocol] = []
        if (try? PairingFileParser.parse(content: content, preferred: .lockdown)) != nil {
            modes.append(.lockdown)
        }
        if (try? PairingFileParser.parse(content: content, preferred: .rppairing)) != nil {
            modes.append(.rppairing)
        }
        return modes
    }

    // Splits a composite plist into one file per selected protocol and saves
    // each via the normal save path (overwrite, App Group mirror). Keys that
    // belong to neither protocol are kept in both subsets so no data is lost.
    // Intentionally does not touch persistedActiveProtocol: the caller decides.
    func importComposite(content: String, modes: [PairingProtocol]) throws {
        guard let data = content.data(using: .utf8),
              let plist = try? PropertyListSerialization.propertyList(from: data, options: [], format: nil) as? [String: Any],
              !plist.isEmpty
        else {
            throw PairingError.invalidPlist("The file could not be parsed as a property list (plist).")
        }
        // Must stay in sync with minimuxer's PairingFile.swift required keys.
        let lockdownKeys: Set<String> = [
            "WiFiMACAddress", "SystemBUID", "RootPrivateKey", "HostPrivateKey",
            "HostID", "RootCertificate", "UDID", "EscrowBag",
            "HostCertificate", "DeviceCertificate"
        ]
        let remotePairingKeys: Set<String> = ["private_key", "public_key", "identifier"]

        for mode in modes {
            let excluded: Set<String>
            switch mode {
            case .lockdown: excluded = remotePairingKeys
            case .rppairing: excluded = lockdownKeys
            case .unknown: continue
            }
            let subset = plist.filter { !excluded.contains($0.key) }
            guard !subset.isEmpty else { continue }
            let subsetData = try PropertyListSerialization.data(fromPropertyList: subset, format: .xml, options: 0)
            guard let subsetContent = String(data: subsetData, encoding: .utf8) else {
                throw PairingError.unreadable("UTF-8 encoding failed")
            }
            // Validate before writing: a subset missing required keys is a bug, fail loudly.
            _ = try PairingFileParser.parse(content: subsetContent, preferred: mode)
            _ = try savePairingFile(contents: subsetContent, preferred: mode)
            debugLog("[PairingFile] Imported \(mode.rawValue) subset from composite pairing file.")
        }
    }

    func deletePairingFile(for mode: PairingProtocol) {
        let fileURL = pairingFileURL(for: mode)
        let fm = FileManager.default
        if fm.fileExists(atPath: fileURL.path) {
            try? fm.removeItem(at: fileURL)
            debugLog("[PairingFile] Deleted \(mode.rawValue) pairing file: \(fileURL.path)")
        }
        if mode == persistedActiveProtocol {
            persistedActiveProtocol = nil
        }
    }

    func resetAllPairingFiles() {
        let fm = FileManager.default
        let files = [
            AppConstants.Pairing.lockdownPairingFileName,
            AppConstants.Pairing.remotePairingFileName,
            AppConstants.Pairing.legacyPairingFileName
        ]
        for name in files {
            let path = fm.documentsDirectory.appendingPathComponent(name)
            if fm.fileExists(atPath: path.path) {
                try? fm.removeItem(at: path)
            }
        }
        UserDefaults.standard.isPairingReset = true
        persistedActiveProtocol = nil
        debugLog("[PairingFile] Reset all pairing files.")
    }
}
