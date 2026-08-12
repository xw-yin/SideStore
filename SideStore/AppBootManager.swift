//
//  AppBootManager.swift
//  SideStore
//
//  Created by Magesh K on 9/7/26.
//  Copyright © 2026 SideStore. All rights reserved.
//

import Foundation
@preconcurrency import AltStoreCore

public final class AppBootManager {
    public static let shared = AppBootManager()
    
    private let lock = NSLock()
    
    private var _needsPairingPrompt = false
    public var needsPairingPrompt: Bool {
        get { lock.withLock { _needsPairingPrompt } }
        set { lock.withLock { _needsPairingPrompt = newValue } }
    }
    
    private var _needsSideJITPrompt = false
    public var needsSideJITPrompt: Bool {
        get { lock.withLock { _needsSideJITPrompt } }
        set { lock.withLock { _needsSideJITPrompt = newValue } }
    }
    
    private init() {}
    
    public nonisolated func getSavedPairingFile() -> String? {
        let fm = FileManager.default
        let pairingFileName = "ALTPairingFile.mobiledevicepairing"
        let documentsPath = fm.documentsDirectory.appendingPathComponent(pairingFileName)
        if fm.fileExists(atPath: documentsPath.path),
           let contents = try? String(contentsOf: documentsPath), !contents.isEmpty {
            return contents
        }
        if let groupURL = fm.containerURL(forSecurityApplicationGroupIdentifier: "group.com.rileytestut.AltStore") {
            let groupPath = groupURL.appendingPathComponent(pairingFileName)
            if fm.fileExists(atPath: groupPath.path),
               let contents = try? String(contentsOf: groupPath), !contents.isEmpty {
                return contents
            }
        }
        if let url = Bundle.main.url(forResource: "ALTPairingFile", withExtension: "mobiledevicepairing"),
           fm.fileExists(atPath: url.path),
           let data = fm.contents(atPath: url.path),
           let contents = String(data: data, encoding: .utf8),
           !contents.isEmpty, !UserDefaults.standard.isPairingReset { return contents }
        if let plistString = Bundle.main.object(forInfoDictionaryKey: "ALTPairingFile") as? String,
           !plistString.isEmpty, !plistString.contains("insert pairing file here"), !UserDefaults.standard.isPairingReset { return plistString }
        return nil
    }
    
    public nonisolated func startMinimuxer(pairingFile: String) async throws {
        debugLog("[AppBootManager] startMinimuxer() entered")
        defer { debugLog("[AppBootManager] startMinimuxer() exited") }
        
        if UserDefaults.standard.enableEMPforWireguard {
            debugLog("[AppBootManager] Starting EMProxy before minimuxer...")
            try await startEMProxy()
        }

        try await minimuxerStart(pairingFile, mountPath: FileManager.default.documentsDirectory.absoluteString)
        
        // Validate the pairing by trying to fetch the UDID
        do {
            debugLog("[AppBootManager] startMinimuxer(): Minimuxer fetchUDID() based connection starting...")
            let deviceUDID = try await fetchUDID()
            debugLog("[AppBootManager] startMinimuxer(): Minimuxer fetchUDID() based connection test SUCCEEDED. UDID: \(deviceUDID ?? "nil")")
            self.needsPairingPrompt = false
        } catch {
            if error.isMinimuxerPairingFile {
                debugLog("[AppBootManager] startMinimuxer(): Minimuxer fetchUDID() based connection test FAILED. \(error)")
                self.needsPairingPrompt = true
                throw error
            } else {
                debugLog("[AppBootManager] startMinimuxer(): Minimuxer fetchUDID() based connection test FAILED but PAIRING FILE IS VALID. \(error)")
            }
        }
    }
    
    private struct MinimuxerStartup {
        let task: Task<Void, Error>
    }
    private static var currentStartup: MinimuxerStartup?
    private static let startupLock = NSLock()

    public nonisolated func ensureMinimuxerStarted() async throws {
        if !UserDefaults.standard.isMinimuxerStatusCheckEnabled {
            return
        }
        #if targetEnvironment(simulator)
        return
        #else
        let status = await getMinimuxerStatus()
        if status == .ready {
            return
        }
        
        let startup: MinimuxerStartup = Self.startupLock.withLock {
            if let existing = Self.currentStartup {
                return existing
            }
            let task = Task {
                guard let pf = self.getSavedPairingFile() else {
                    self.needsPairingPrompt = true
                    throw OperationError.invalidPairingFile(reason: nil)
                }
                try await self.startMinimuxer(pairingFile: pf)
            }
            let newStartup = MinimuxerStartup(task: task)
            Self.currentStartup = newStartup
            return newStartup
        }
        
        do {
            try await startup.task.value
            Self.startupLock.withLock { Self.currentStartup = nil }
        } catch {
            Self.startupLock.withLock { Self.currentStartup = nil }
            throw error
        }
        #endif
    }
    
    public nonisolated func performBootSequence() async {
        Task.detached {
            debugLog("[AppBootManager] performBootSequence() entered")
            defer {
                debugLog("[AppBootManager] performBootSequence() exited")
            }
            // 1. Structured concurrent child task A
            async let jitCheck: Void = {
                debugLog("[AppBootManager] performBootSequence(): JIT check starting")
                defer {
                    debugLog("[AppBootManager] performBootSequence(): JIT check completed")
                }
                if #available(iOS 17, *), !UserDefaults.standard.sidejitenable {
                    do {
                        try await self.isSideJITServerDetected()
                        await MainActor.run {
                            self.needsSideJITPrompt = true
                        }
                    } catch {
                        debugLog("[AppBootManager] Cannot find sideJITServer")
                    }
                }
                
                if #available(iOS 17, *), UserDefaults.standard.sidejitenable {
                    await self.askForNetwork()
                    debugLog("[AppBootManager] SideJITServer Enabled")
                }
            }()
            
            // 2. Structured concurrent child task B
            async let minimuxerCheck: Void = {
                debugLog("[AppBootManager] performBootSequence(): Minimuxer check starting")
                defer {
                    debugLog("[AppBootManager] performBootSequence(): Minimuxer check completed")
                }
                #if targetEnvironment(simulator)
                do {
                    try await self.startMinimuxer(pairingFile: "ignored-for-sim")
                } catch {
                    debugLog("[AppBootManager] Failed to start minimuxer: \(error)")
                }
                #else
                if let pf = self.getSavedPairingFile() {
                    do {
                        try await self.startMinimuxer(pairingFile: pf)
                    } catch {
                        debugLog("[AppBootManager] Failed to start minimuxer: \(error)")
                    }
                } else {
                    debugLog("[AppBootManager] No pairing file found, proceeding for LiveContainer UI")
                }
                #endif
            }()
            
            _ = await (jitCheck, minimuxerCheck)
        }
    }
    
    private nonisolated func askForNetwork() async {
        let address = UserDefaults.standard.textInputSideJITServerurl ?? ""
        let SJSURL = address.isEmpty ? "http://sidejitserver._http._tcp.local:8080" : address
        guard let url = URL(string: "\(SJSURL)/re/") else { return }
        do {
            var request = URLRequest(url: url)
            request.timeoutInterval = 2.0
            
            try await withThrowingTaskGroup(of: Void.self) { group in
                group.addTask {
                    let (data, response) = try await URLSession.shared.data(for: request)
                    debugLog("data: \(data), response: \(response)")
                }
                group.addTask {
                    try await Task.sleep(nanoseconds: 2_000_000_000) // 2.0 seconds
                    throw URLError(.timedOut)
                }
                try await group.next()
                group.cancelAll()
            }
        } catch {
            debugLog("error: \(error)")
        }
    }

    private nonisolated func isSideJITServerDetected() async throws {
        let address = UserDefaults.standard.textInputSideJITServerurl ?? ""
        let SJSURL = address.isEmpty ? "http://sidejitserver._http._tcp.local:8080" : address
        guard let url = URL(string: SJSURL) else { throw URLError(.badURL) }
        var request = URLRequest(url: url)
        request.timeoutInterval = 2.0
        
        try await withThrowingTaskGroup(of: Void.self) { group in
            group.addTask {
                _ = try await URLSession.shared.data(for: request)
            }
            group.addTask {
                try await Task.sleep(nanoseconds: 2_000_000_000) // 2.0 seconds
                throw URLError(.timedOut)
            }
            try await group.next()
            group.cancelAll()
        }
    }
}
