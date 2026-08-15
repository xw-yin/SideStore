//
//  AppBootManager.swift
//  SideStore
//
//  Created by Magesh K on 9/7/26.
//  Copyright © 2026 SideStore. All rights reserved.
//

import Foundation

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

            // Device validation can wait on the network. It must not hold refresh operations.
            Task.detached { [weak self] in
                await self?.validateMinimuxerConnection()
            }
        } catch {
            if error.isMinimuxerPairingFile {
                self.needsPairingPrompt = true
            }
            debugLog("[AppBootManager] Minimuxer startup task failed: \(error)")
            throw error
        }
    }

    private nonisolated func validateMinimuxerConnection() async {
        do {
            debugLog("[AppBootManager] startMinimuxer(): Minimuxer fetchUDID() based connection starting...")
            let deviceUDID = try await fetchUDID()
            debugLog("[AppBootManager] startMinimuxer(): Minimuxer fetchUDID() based connection test SUCCEEDED. UDID: \(deviceUDID ?? "nil")")
            self.needsPairingPrompt = false
        } catch {
            if error.isMinimuxerPairingFile {
                debugLog("[AppBootManager] startMinimuxer(): Minimuxer fetchUDID() based connection test FAILED. \(error)")
                self.needsPairingPrompt = true
            } else {
                debugLog("[AppBootManager] startMinimuxer(): Minimuxer fetchUDID() based connection test FAILED but PAIRING FILE IS VALID. \(error)")
            }
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
                if minimuxerStartup?.generation == startup.generation {
                    minimuxerStartup = nil
                }
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

        guard let pairingFile = PairingFileManager.shared.fetchPairingFile() else {
            self.needsPairingPrompt = true
            throw OperationError.invalidPairingFile(reason: nil)
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
        // 1. Structured concurrent child task A
        async let jitCheck: Void = {
            debugLog("[AppBootManager] performBootSequence(): JIT check starting")
            defer {
                debugLog("[AppBootManager] performBootSequence(): JIT check completed")
            }
            if #available(iOS 17, *), !UserDefaults.standard.sidejitenable {
                do {
                    try await SideJITManager.shared.isSideJITServerDetected()
                    self.needsSideJITPrompt = true
                } catch {
                    debugLog("[AppBootManager] Cannot find sideJITServer")
                }
            }
            
            if #available(iOS 17, *), UserDefaults.standard.sidejitenable {
                await SideJITManager.shared.askForNetwork()
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
            if PairingFileManager.shared.fetchPairingFile() != nil {
                do {
                    try await self.ensureMinimuxerStarted()
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
