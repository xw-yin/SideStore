//
//  AppBootManager.swift
//  SideStore
//
//  Created by Magesh K on 9/7/26.
//  Copyright © 2026 SideStore. All rights reserved.
//

import Foundation
import Minimuxer

public final class AppBootManager: @unchecked Sendable {
    public static let shared = AppBootManager()

    private struct MinimuxerStartup {
        let generation: UInt
        let task: Task<Void, Error>
    }
    
    private let lock = NSLock()
    private var minimuxerStartup: MinimuxerStartup?
    private var minimuxerStartupGeneration: UInt = 0
    
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
    
    // @livecontainer: App Group pairing file scan
    public nonisolated func getSavedPairingFile() -> String? {
        let fm = FileManager.default
        let pairingFileName = "ALTPairingFile.mobiledevicepairing"
        var fileURLs = [fm.documentsDirectory.appendingPathComponent(pairingFileName)]
        if let groupURL = fm.altstoreSharedDirectory {
            fileURLs.append(groupURL.appendingPathComponent(pairingFileName))
            fileURLs.append(groupURL.appendingPathComponent("Documents").appendingPathComponent(pairingFileName))
        }

        for fileURL in fileURLs {
            if fm.fileExists(atPath: fileURL.path),
               let contents = try? String(contentsOf: fileURL), !contents.isEmpty {
                return contents
            }
        }

        guard !UserDefaults.standard.isPairingReset else { return nil }
        for bundle in [Bundle.main, Bundle.realMainBundle] {
            if let url = bundle.url(forResource: "ALTPairingFile", withExtension: "mobiledevicepairing"),
               fm.fileExists(atPath: url.path),
               let data = fm.contents(atPath: url.path),
               let contents = String(data: data, encoding: .utf8),
               !contents.isEmpty {
                return contents
            }
            if let plistString = bundle.object(forInfoDictionaryKey: "ALTPairingFile") as? String,
               !plistString.isEmpty,
               !plistString.contains("insert pairing file here") {
                return plistString
            }
        }
        return nil
    }
    
    private nonisolated func runMinimuxerStartup(pairingFile: String, generation: UInt) async throws {
        debugLog("[AppBootManager] Minimuxer startup task entered")
        do {
            if UserDefaults.standard.enableEMPforWireguard {
                debugLog("[AppBootManager] Starting EMProxy before minimuxer...")
                try await startEMProxy()
            }

            try await minimuxerStart(pairingFile, mountPath: FileManager.default.documentsDirectory.absoluteString)
            lock.withLock {
                if minimuxerStartup?.generation == generation {
                    _needsPairingPrompt = false
                }
            }
            debugLog("[AppBootManager] Minimuxer startup task completed")
        } catch {
            if error.isMinimuxerPairingFile {
                needsPairingPrompt = true
            }
            debugLog("[AppBootManager] Minimuxer startup task failed: \(error)")
            throw error
        }
    }

    private nonisolated func makeMinimuxerStartup(pairingFile: String) -> MinimuxerStartup {
        lock.withLock {
            if let startup = minimuxerStartup {
                return startup
            }

            minimuxerStartupGeneration &+= 1
            let generation = minimuxerStartupGeneration
            let task = Task.detached(priority: .userInitiated) { [weak self] in
                guard let self else { throw CancellationError() }
                try await self.runMinimuxerStartup(pairingFile: pairingFile, generation: generation)
            }
            let startup = MinimuxerStartup(generation: generation, task: task)
            minimuxerStartup = startup
            return startup
        }
    }

    private nonisolated func waitForMinimuxerStartup(_ startup: MinimuxerStartup) async throws {
        defer {
            lock.withLock {
                guard minimuxerStartup?.generation == startup.generation else { return }
                minimuxerStartup = nil
            }
        }
        try await startup.task.value
    }

    public nonisolated func startMinimuxer(pairingFile: String) async throws {
        let startup = makeMinimuxerStartup(pairingFile: pairingFile)
        try await waitForMinimuxerStartup(startup)
    }

    public nonisolated func ensureMinimuxerStarted() async throws {
        #if targetEnvironment(simulator)
        return
        #else
        let status = await getMinimuxerStatus()
        if status == .ready {
            return
        }

        guard let pairingFile = getSavedPairingFile() else {
            needsPairingPrompt = true
            throw OperationError.invalidPairingFile()
        }

        let startup = makeMinimuxerStartup(pairingFile: pairingFile)
        try await waitForMinimuxerStartup(startup)
        #endif
    }

    public nonisolated func performBootSequence() async {
        debugLog("[AppBootManager] performBootSequence() entered")
        defer {
            debugLog("[AppBootManager] performBootSequence() exited")
        }

        async let jitCheck: Void = {
            debugLog("[AppBootManager] performBootSequence(): JIT check starting")
            defer {
                debugLog("[AppBootManager] performBootSequence(): JIT check completed")
            }
            if #available(iOS 17, *), !UserDefaults.standard.isSideJITServerEnabled {
                do {
                    try await SideJITManager.shared.isSideJITServerDetected()
                    self.needsSideJITPrompt = true
                } catch {
                    debugLog("[AppBootManager] Cannot find sideJITServer")
                }
            }

            if #available(iOS 17, *), UserDefaults.standard.isSideJITServerEnabled {
                await SideJITManager.shared.askForNetwork()
                debugLog("[AppBootManager] SideJITServer Enabled")
            }
        }()

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
            do {
                try await self.ensureMinimuxerStarted()
            } catch {
                debugLog("[AppBootManager] Failed to ensure minimuxer: \(error)")
            }
            #endif
        }()

        _ = await (jitCheck, minimuxerCheck)
    }
}
