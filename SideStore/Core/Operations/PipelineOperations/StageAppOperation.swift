//
//  StageAppOperation.swift
//  SideStore
//
//  Created by Magesh K on 31/7/26.
//  Copyright © 2026 AltStore. All rights reserved.
//

@preconcurrency import UIKit
import Foundation
import SideSign

final class StageAppOperation: BasePipelineOperation<InstallAppOperationContext, ALTApplication>, @unchecked Sendable {
    
    override func execute(parentProgress: Progress?) async throws -> ALTApplication {
        let startTime = CFAbsoluteTimeGetCurrent()
        debugLog("[StageAppOperation] execute() started")
        defer {
            let elapsed = CFAbsoluteTimeGetCurrent() - startTime
            debugLog("[StageAppOperation] execute() took: \(String(format: "%.3fs", elapsed))")
        }
        try await super.executePreconditionCheck(parentProgress: parentProgress)
        self.setProgress(10)
        
        if let appBundle = self.context.targetAppBundle,
           appBundle.bundle.bundleURL.path.contains("SideBackup") || appBundle.bundle.bundleURL.path.contains("AltBackup"),
           let installedApp = self.context.installedApp {
            self.context.targetAppBundle = self.resolveAppBundle(for: installedApp)
        }
        
        if self.context.targetAppBundle == nil, let installedApp = self.context.installedApp {
            self.context.targetAppBundle = self.resolveAppBundle(for: installedApp)
        }
        
        guard let appBundle = self.context.targetAppBundle else {
            if let installedApp = self.context.installedApp {
                throw OperationError.missingAppBundle(reason: "Could not find or load app bundle for '\(installedApp.name)'. Please reinstall or refresh the app.")
            } else {
                throw OperationError.invalidParameters("StageAppOperation: context.appBundle is nil")
            }
        }
        
        let fileURL = appBundle.fileURL
        let tempDir = self.context.temporaryDirectory
        
        self.setProgress(30)
        if !FileManager.default.fileExists(atPath: tempDir.path) {
            try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true, attributes: nil)
        }
        
        if fileURL.path.hasPrefix(tempDir.path) {
            debugLog("[StageAppOperation] App is already in temporary directory: \(fileURL)")
            self.setProgress(100)
            return appBundle
        }
        
        let destinationURL = tempDir.appendingPathComponent(fileURL.lastPathComponent)
        debugLog("[StageAppOperation] Copying cached app from \(fileURL) to \(destinationURL)")
        
        self.setProgress(60)
        if FileManager.default.fileExists(atPath: destinationURL.path) {
            debugLog("[StageAppOperation] Removing pre-existing app bundle at destination: \(destinationURL)")
            try FileManager.default.removeItem(at: destinationURL)
        }
        
        self.setProgress(80)
        debugLog("[StageAppOperation] Copying item from \(fileURL) to \(destinationURL)")
        try FileManager.default.copyItem(at: fileURL, to: destinationURL)
        debugLog("[StageAppOperation] Successfully copied app bundle to destination.")
        
        guard let stagedAppBundle = ALTApplication(fileURL: destinationURL) else {
            throw OperationError.missingAppBundle(reason: "Could not load staged app bundle at '\(destinationURL.lastPathComponent)'")
        }
        
        self.context.targetAppBundle = stagedAppBundle
        
        if self.context.appBundleFingerprint == nil {
            if let (signature, _) = try? CacheAppOperation.cachePayload(for: stagedAppBundle.fileURL) {
                self.context.appBundleFingerprint = signature
            } else if let signature = AppBundleFingerprint.compute(for: stagedAppBundle.fileURL) {
                self.context.appBundleFingerprint = signature
            }
        }
        
        self.setProgress(100)
        return stagedAppBundle
    }
    
    private func resolveAppBundle(for installedApp: InstalledApp) -> ALTApplication? {
        if let appBundle = ALTApplication(fileURL: installedApp.fileURL) {
            return appBundle
        }
        
        if installedApp.bundleIdentifier == StoreApp.altstoreAppID || installedApp.bundleIdentifier.isAltStoreAppID {
            let hostURL = Bundle.isBundledWithLiveContainer ? Bundle.realMainBundle.bundleURL : Bundle.Info.activeBundleURL
            if let appBundle = ALTApplication(fileURL: hostURL) {
                return appBundle
            }
        }
        
        if let contents = try? FileManager.default.contentsOfDirectory(at: installedApp.directoryURL, includingPropertiesForKeys: nil),
           let appURL = contents.first(where: { $0.pathExtension == "app" }),
           let appBundle = ALTApplication(fileURL: appURL) {
            return appBundle
        }
        
        let legacyCandidates = [
            InstalledApp.legacyAppsDirectoryURL.appendingPathComponent(installedApp.resignedBundleIdentifier).appendingPathComponent("App.app"),
            InstalledApp.legacyAppsDirectoryURL.appendingPathComponent(installedApp.bundleIdentifier).appendingPathComponent("App.app"),
            InstalledApp.appsDirectoryURL.appendingPathComponent(installedApp.bundleIdentifier).appendingPathComponent("App.app")
        ]
        for candidate in legacyCandidates where FileManager.default.fileExists(atPath: candidate.path) {
            if let appBundle = ALTApplication(fileURL: candidate) {
                return appBundle
            }
        }
        
        let candidateIPAs: [URL] = [
            installedApp.refreshedIPAURL,
            installedApp.directoryURL.appendingPathComponent("\(installedApp.bundleIdentifier).ipa"),
            installedApp.directoryURL.appendingPathComponent("\(installedApp.resignedBundleIdentifier).ipa")
        ] + ((try? FileManager.default.contentsOfDirectory(at: installedApp.directoryURL, includingPropertiesForKeys: nil).filter { $0.pathExtension == "ipa" }) ?? [])
        
        let tempDir = self.context.temporaryDirectory
        for ipaURL in candidateIPAs where FileManager.default.fileExists(atPath: ipaURL.path) {
            do {
                if !FileManager.default.fileExists(atPath: tempDir.path) {
                    try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true, attributes: nil)
                }
                let unzippedURL = try FileManager.default.unzipAppBundle(at: ipaURL, toDirectory: tempDir)
                if let appBundle = ALTApplication(fileURL: unzippedURL) {
                    debugLog("[StageAppOperation] Recovered app bundle by unzipping \(ipaURL.lastPathComponent)")
                    return appBundle
                }
            } catch {
                debugLog("[StageAppOperation] Failed to unzip IPA at \(ipaURL.path): \(error)")
            }
        }
        
        return nil
    }
}
