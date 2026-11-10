//
//  AppBootManager.swift
//  SideStore
//
//  Created by Magesh K on 9/7/26.
//  Copyright © 2026 SideStore. All rights reserved.
//

import Foundation
import UIKit
import Minimuxer

/// Resumes a continuation with whichever of several racing producers
/// finishes first; later results are dropped.
private final class FirstResultRace<T>: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<T, Never>?

    init(_ continuation: CheckedContinuation<T, Never>) {
        self.continuation = continuation
    }

    func resume(with value: T) {
        let winner = lock.withLock { () -> CheckedContinuation<T, Never>? in
            defer { continuation = nil }
            return continuation
        }
        winner?.resume(returning: value)
    }
}

public final class AppBootManager: @unchecked Sendable {
    public static let shared = AppBootManager()

    private struct MinimuxerStartup {
        let generation: UInt
        let task: Task<Void, Error>
    }
    
    private let lock = NSLock()
    private var minimuxerStartup: MinimuxerStartup?
    private var minimuxerStartupGeneration: UInt = 0
    private var lastForegroundReconnectTime: Date = .distantPast
    private var isReconnectingOnForeground = false
    
    private var cachedNeedsPairingPrompt = false
    public var needsPairingPrompt: Bool {
        get { lock.withLock { cachedNeedsPairingPrompt } }
        set { lock.withLock { cachedNeedsPairingPrompt = newValue } }
    }
    
    private var cachedNeedsSideJITPrompt = false
    public var needsSideJITPrompt: Bool {
        get { lock.withLock { cachedNeedsSideJITPrompt } }
        set { lock.withLock { cachedNeedsSideJITPrompt = newValue } }
    }
    
    private init() {}
    
    // @livecontainer: App Group pairing file scan
    public nonisolated func getSavedPairingFile() -> String? {
        guard !UserDefaults.standard.isPairingReset else { return nil }
        let fm = FileManager.default
        let manager = PairingFileManager.shared
        let pairingFileName = manager.pairingFileURL(for: manager.defaultProtocol()).lastPathComponent
        let fileNames = [pairingFileName, AppConstants.Pairing.legacyPairingFileName]
        var directories = [fm.documentsDirectory]
        if let groupURL = fm.altstoreSharedDirectory {
            directories.append(groupURL)
            directories.append(groupURL.appendingPathComponent("Documents"))
        }

        // Resolve only the protocol supported by this OS, including legacy and
        // LiveContainer shared-container files. Real-device pairing needs proper testing.
        for directory in directories {
            for name in fileNames {
                let fileURL = directory.appendingPathComponent(name)
                if let contents = try? String(contentsOf: fileURL),
                   (try? manager.parse(content: contents)) != nil {
                    return contents
                }
            }
        }
        for bundle in [Bundle.main, Bundle.realMainBundle] {
            if let url = bundle.url(forResource: "ALTPairingFile", withExtension: "mobiledevicepairing"),
               fm.fileExists(atPath: url.path),
               let data = fm.contents(atPath: url.path),
               let contents = String(data: data, encoding: .utf8),
               (try? manager.parse(content: contents)) != nil {
                return contents
            }
            if let plistString = bundle.object(forInfoDictionaryKey: "ALTPairingFile") as? String,
               !plistString.isEmpty,
               !plistString.contains("insert pairing file here"),
               (try? manager.parse(content: plistString)) != nil {
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
                    cachedNeedsPairingPrompt = false
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

    /// Upper bound for waiting on a minimuxer startup. A startup that stalls
    /// (e.g. the app was backgrounded mid-start and the connection died under
    /// it) must not wedge every later caller: all operations share the cached
    /// startup task, so an unbounded wait here silently disables refresh,
    /// deactivate, install, etc. until the app is relaunched.
    private static let minimuxerStartupTimeout: TimeInterval = 30

    private nonisolated func waitForMinimuxerStartup(_ startup: MinimuxerStartup) async throws {
        defer {
            // Runs on success, failure, and timeout alike: once a waiter gives
            // up, the cached startup is dropped so the next call starts fresh
            // instead of awaiting the same (possibly stalled) task again.
            lock.withLock {
                guard minimuxerStartup?.generation == startup.generation else { return }
                minimuxerStartup = nil
            }
        }
        try await withThrowingTaskGroup(of: Void.self) { group in
            group.addTask {
                try await startup.task.value
            }
            group.addTask {
                try await Task.sleep(nanoseconds: UInt64(Self.minimuxerStartupTimeout * 1_000_000_000))
                throw OperationError.notReachable(reason: "Timed out after \(Int(Self.minimuxerStartupTimeout))s waiting for minimuxer to start. The previous startup may have stalled while the app was in the background; please try again.")
            }
            _ = try await group.next()
            group.cancelAll()
        }
    }

    /// Drops any cached startup task so subsequent operations start fresh.
    public nonisolated func invalidateStalledStartup() {
        lock.withLock {
            minimuxerStartup = nil
        }
    }

    /// Status check with a bound: `isReady()` probes the device through the
    /// same stack a stalled startup can block, so it gets its own timeout and
    /// reports `.unknown` (i.e. not ready) instead of hanging the caller.
    /// unstructured tasks are used on purpose: a task group would still wait
    /// for the probe on scope exit even after cancelling it, while here the
    /// loser is simply abandoned and finishes (or not) in the background.
    private nonisolated func minimuxerStatusWithTimeout(timeoutSeconds: Double = 3.5) async -> MinimuxerStatus {
        await withCheckedContinuation { (continuation: CheckedContinuation<MinimuxerStatus, Never>) in
            let race = FirstResultRace(continuation)
            Task.detached {
                race.resume(with: await getMinimuxerStatus())
            }
            Task.detached {
                let nanos = UInt64(timeoutSeconds * 1_000_000_000)
                try? await Task.sleep(nanoseconds: nanos)
                race.resume(with: .unknown)
            }
        }
    }

    /// Proactively checks minimuxer readiness on foreground transition and self-heals
    /// the connection if it was severed while suspended in the background.
    public nonisolated func reconnectOnForegroundIfNeeded(force: Bool = false) async {
        #if targetEnvironment(simulator)
        return
        #else
        let now = Date()
        let shouldRun = lock.withLock { () -> Bool in
            if isReconnectingOnForeground { return false }
            if !force && now.timeIntervalSince(lastForegroundReconnectTime) < 5.0 {
                return false
            }
            isReconnectingOnForeground = true
            lastForegroundReconnectTime = now
            return true
        }
        guard shouldRun else { return }
        defer {
            lock.withLock { isReconnectingOnForeground = false }
        }

        debugLog("[AppBootManager] Checking minimuxer connection on foreground...")
        let status = await minimuxerStatusWithTimeout(timeoutSeconds: 3.0)
        if status == .ready {
            debugLog("[AppBootManager] Minimuxer is healthy on foreground, no reconnect needed.")
            return
        }

        debugLog("[AppBootManager] Minimuxer not ready on foreground (\(status)). Triggering recovery...")
        _ = await recoverConnection()
        #endif
    }

    /// Recovers broken minimuxer connection by invalidating stale tasks and restarting services.
    @discardableResult
    public nonisolated func recoverConnection() async -> Bool {
        #if targetEnvironment(simulator)
        return true
        #else
        invalidateStalledStartup()
        do {
            debugLog("[AppBootManager] recoverConnection: restarting minimuxer...")
            try await minimuxerRestart()
            debugLog("[AppBootManager] recoverConnection: minimuxer restarted successfully.")
            return true
        } catch {
            debugLog("[AppBootManager] recoverConnection: minimuxerRestart failed (\(error)), falling back to ensureMinimuxerStarted()...")
            do {
                try await ensureMinimuxerStarted()
                return true
            } catch {
                debugLog("[AppBootManager] recoverConnection: fallback failed: \(error)")
                return false
            }
        }
        #endif
    }

    public nonisolated func startMinimuxer(pairingFile: String) async throws {
        let startup = makeMinimuxerStartup(pairingFile: pairingFile)
        try await waitForMinimuxerStartup(startup)
    }

    public nonisolated func ensureMinimuxerStarted() async throws {
        #if targetEnvironment(simulator)
        return
        #else
        let status = await minimuxerStatusWithTimeout()
        if status == .ready {
            return
        }

        guard let pairingFile = getSavedPairingFile() else {
            needsPairingPrompt = true
            throw OperationError.invalidPairingFile(reason: "No saved pairing file found")
        }

        let startup = makeMinimuxerStartup(pairingFile: pairingFile)
        try await waitForMinimuxerStartup(startup)
        #endif
    }
    
    @MainActor
    public func promptForPairing(on vc: UIViewController) async {
        var isRetry = false
        while true {
            guard let selectedURL = await withCheckedContinuation({ (continuation: CheckedContinuation<URL?, Never>) in
                PairingViewController.shared.presentPairingFileAlert(on: vc, isRetry: isRetry) { selectedURL in
                    debugLog("[AppBootManager] promptForPairing: alert completed with selectedURL: \(selectedURL?.path ?? "nil")")
                    continuation.resume(returning: selectedURL)
                }
            }) else {
                debugLog("[AppBootManager] promptForPairing: user skipped or cancelled pairing prompt")
                break
            }
            
            debugLog("[AppBootManager] promptForPairing: fetching pairing file at selectedURL: \(selectedURL.path)")
            guard let pairingString = PairingFileManager.shared.fetchPairingFile() else {
                debugLog("[AppBootManager] promptForPairing: failed to read saved pairing file from disk")
                isRetry = true
                continue
            }
            
            do {
                try await self.startMinimuxer(pairingFile: pairingString)
                self.needsPairingPrompt = false
                break
            } catch {
                debugLog("[AppBootManager] startMinimuxer failed with pairing file: \(error)")
                let didSwitch = await PairingViewController.shared.handlePotentialProtocolMismatch(
                    on: vc,
                    pairingContent: pairingString
                )
                if didSwitch {
                    do {
                        try await self.startMinimuxer(pairingFile: pairingString)
                        self.needsPairingPrompt = false
                        break
                    } catch {
                        debugLog("[AppBootManager] startMinimuxer retry after protocol switch failed: \(error)")
                    }
                }
                isRetry = true
            }
        }
    }
    
    public nonisolated func performBootSequence() async {
        debugLog("[AppBootManager] performBootSequence() entered")
        defer { debugLog("[AppBootManager] performBootSequence() exited") }
        
        async let jitCheck: Void = {
            debugLog("[AppBootManager] performBootSequence(): JIT check starting")
            defer { debugLog("[AppBootManager] performBootSequence(): JIT check completed") }
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
