//
//  MinimuxerWrapper.swift
//
//  Created by Magesh K on 22/02/26.
//  Copyright © 2026 SideStore. All rights reserved.
//

import Foundation

var isMinimuxerReady: Bool {
    #if targetEnvironment(simulator)
    print("isMinimuxerReady property is always true on simulator")
    return true
    #else
    do {
        try JITEnableContext.shared.ensureTunnel()
        return true
    } catch {
        return false
    }
    #endif
}

func minimuxerStartWithLogger(_ pairingFile: String, _ logPath: String, _ loggingEnabled: Bool) throws {
    #if targetEnvironment(simulator)
    print("minimuxerStartWithLogger(\(pairingFile), \(logPath), \(loggingEnabled)) is no-op on simulator")
    #else
    print("minimuxerStartWithLogger(\(pairingFile), \(logPath), \(loggingEnabled))")
    JITEnableContext.shared.initLogger(withLogPath: URL(string: logPath)!.appendingPathComponent("idevice_log.txt").path, loggingEnabled: loggingEnabled)
    try JITEnableContext.shared.ensureTunnel()
    #endif
}

func targetMinimuxerAddress() {
    #if targetEnvironment(simulator)
    print("targetMinimuxerAddress() is no-op on simulator")
    #else
    UserDefaults.standard.set("customTargetIP", forKey: "10.7.0.1")
    #endif
}

func installProvisioningProfiles(_ profileData: Data) throws {
    #if targetEnvironment(simulator)
    print("installProvisioningProfiles(\(profileData)) is no-op on simulator")
    #else
    try JITEnableContext.shared.addProfile(profileData)
    #endif
}

func removeProvisioningProfile(_ uuid: String) throws {
    #if targetEnvironment(simulator)
    print("removeProvisioningProfile(\(uuid)) is no-op on simulator")
    #else
    try JITEnableContext.shared.removeProfile(withUUID: uuid)
    #endif
}


func removeApp(_ bundleId: String) throws {
    #if targetEnvironment(simulator)
    print("removeApp(\(bundleId)) is no-op on simulator")
    #else
    try JITEnableContext.shared.uninstallApp(withBundleID: bundleId)
    #endif
}


func yeetAppAFC(_ bundleId: String, _ rawBytes: Data) throws {
    #if targetEnvironment(simulator)
    print("yeetAppAFC(\(bundleId), \(rawBytes)) is no-op on simulator")
    #else
    
    try JITEnableContext.shared.send(rawBytes, toDevicePath: "PublicStaging/\(bundleId)/app.ipa") { bytesSent, totalBytes in
        print("Sending \(bundleId) \(bytesSent)/\(totalBytes)")
    }
    #endif
}


func installIPA(_ bundleId: String) throws {
    #if targetEnvironment(simulator)
    print("installIPA(\(bundleId)) is no-op on simulator")
    #else
    try JITEnableContext.shared.installApp(withPackagePath: "PublicStaging/\(bundleId)/app.ipa")
    #endif
}


func fetchUDID() -> String? {
    #if targetEnvironment(simulator)
    print("fetchUDID() is no-op on simulator")
    return "XXXXX-XXXX-XXXXX-XXXX"
    #else
    do {
        return try JITEnableContext.shared.ideviceInfoGetXML(withKey: "UniqueDeviceID") as? String
    } catch {
        print("fetchUDID failed with error \(error)")
        return nil
    }

    #endif
}

func debugApp(_ bundleId: String) throws {
    #if targetEnvironment(simulator)
    print("removeApp(\(bundleId)) is no-op on simulator")
    #else

    #endif
}


private struct DDIDownloadItem {
    let name: String
    let relativePath: String
    let urlString: String
}

private let ddiDownloadItems: [DDIDownloadItem] = [
    .init(
        name: "Build Manifest",
        relativePath: "DMG/BuildManifest.plist",
        urlString: "https://github.com/doronz88/DeveloperDiskImage/raw/refs/heads/main/PersonalizedImages/Xcode_iOS_DDI_Personalized/BuildManifest.plist"
    ),
    .init(
        name: "Image",
        relativePath: "DMG/Image.dmg",
        urlString: "https://github.com/doronz88/DeveloperDiskImage/raw/refs/heads/main/PersonalizedImages/Xcode_iOS_DDI_Personalized/Image.dmg"
    ),
    .init(
        name: "TrustCache",
        relativePath: "DMG/Image.dmg.trustcache",
        urlString: "https://github.com/doronz88/DeveloperDiskImage/raw/refs/heads/main/PersonalizedImages/Xcode_iOS_DDI_Personalized/Image.dmg.trustcache"
    )
]

private enum DDIDownloadError: LocalizedError {
    case invalidURL(String)
    
    var errorDescription: String? {
        switch self {
        case .invalidURL(let string):
            return "Invalid download URL: \(string)"
        }
    }
}

private func downloadFile(from urlString: String, to destinationURL: URL) async throws {
    guard let url = URL(string: urlString) else {
        throw DDIDownloadError.invalidURL(urlString)
    }
    let (tempLocalUrl, _) = try await URLSession.shared.download(from: url)
    let fileManager = FileManager.default
    try fileManager.createDirectory(at: destinationURL.deletingLastPathComponent(),
                                    withIntermediateDirectories: true)
    if fileManager.fileExists(atPath: destinationURL.path) {
        try fileManager.removeItem(at: destinationURL)
    }
    try fileManager.moveItem(at: tempLocalUrl, to: destinationURL)
}

private func redownloadDDI(destination: URL, progressHandler: ((Double, String) -> Void)? = nil) async throws {
    let fileManager = FileManager.default
    let totalStages = Double(ddiDownloadItems.count + 1)
    var completedStages = 0.0
    
    progressHandler?(0.0, "Removing existing DDI files…")
    for item in ddiDownloadItems {
        let fileURL = destination.appendingPathComponent(item.relativePath)
        if fileManager.fileExists(atPath: fileURL.path) {
            try fileManager.removeItem(at: fileURL)
        }
    }
    completedStages += 1.0
    progressHandler?(completedStages / totalStages, "Starting downloads…")
    
    for item in ddiDownloadItems {
        progressHandler?(completedStages / totalStages, "Downloading \(item.name)…")
        let destinationURL = destination.appendingPathComponent(item.relativePath)
        try await downloadFile(from: item.urlString, to: destinationURL)
        completedStages += 1.0
        progressHandler?(completedStages / totalStages, "\(item.name) ready")
    }
    progressHandler?(1.0, "DDI download complete.")
}


func startAutoMounter(_ dir: String) {
    #if targetEnvironment(simulator)
    print("startAutoMounter is no-op on simulator")
    #else
    Task {
        let dirURL = URL(string: dir)!
        var shouldDownload = false
        for ddiDownloadItem in ddiDownloadItems {
            if !FileManager.default.fileExists(atPath: dirURL.appendingPathComponent(ddiDownloadItem.relativePath).absoluteString) {
                shouldDownload = true
                break
            }
        }
        if shouldDownload {
            do {
                try await redownloadDDI(destination: dirURL)
            } catch {
                print("redownloadDDI failed with error \(error)")
            }
        }
        
        do {

            try JITEnableContext.shared.mountPersonalDDI(
                withImagePath: dirURL.appendingPathComponent("DMG/Image.dmg").path,
                trustcachePath: dirURL.appendingPathComponent("DMG/Image.dmg.trustcache").path,
                manifestPath: dirURL.appendingPathComponent("DMG/BuildManifest.plist").path)
        } catch {
            print("Auto Mounter failed with error \(error)")
        }
    }

    #endif
}

enum MinimuxerError {
    case NoConnection
    case RwAfc
    case ProfileInstall
}

extension MinimuxerError: @retroactive LocalizedError {
    public var failureReason: String? {
        switch self {

        case .NoConnection:
            return NSLocalizedString("Unable to connect to the device, make sure LocalDevVPN is enabled and you're connected to Wi-Fi. This could mean an invalid pairing.", comment: "")

        case .RwAfc:
            return NSLocalizedString("AFC was unable to manage files on the device. Ensure Wi-Fi and LocalDevVPN are connected. If they both are, replace your pairing using iloader.", comment: "")

        case .ProfileInstall:
            return NSLocalizedString("Unable to manage profiles on the device", comment: "")

        }
    }
}
