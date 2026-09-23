//
//  RefreshVerificationManifest.swift
//  SideStore
//
//  Auth preflight + verification manifest for automatic background refresh.
//  Records what was checked before a background run so failures are diagnosable.
//

import Foundation

/// Result of the preflight checks run before an automatic background refresh.
struct RefreshVerificationManifest: Codable
{
    var date: Date
    var hasActiveTeam: Bool
    var hasPairingFile: Bool
    var minimuxerReady: Bool
    var failureReason: String?
    
    var isValid: Bool {
        hasActiveTeam && hasPairingFile && minimuxerReady
    }
    
    var summary: String {
        var parts = [String]()
        parts.append("team=\(hasActiveTeam ? "ok" : "missing")")
        parts.append("pairing=\(hasPairingFile ? "ok" : "missing")")
        parts.append("minimuxer=\(minimuxerReady ? "ok" : "not-ready")")
        if let reason = failureReason {
            parts.append("reason=\(reason)")
        }
        return parts.joined(separator: " ")
    }
    
    /// Runs the preflight checks. Must be cheap: no network, no signing.
    static func verify() async -> RefreshVerificationManifest
    {
        var manifest = RefreshVerificationManifest(
            date: Date(),
            hasActiveTeam: false,
            hasPairingFile: false,
            minimuxerReady: false,
            failureReason: nil
        )
        
        // 1. An Apple team must be signed in.
        let context = DatabaseManager.shared.persistentContainer.newBackgroundContext()
        let hasTeam: Bool = await context.perform {
            DatabaseManager.shared.activeTeam(in: context) != nil
        }
        manifest.hasActiveTeam = hasTeam
        guard hasTeam else {
            manifest.failureReason = "No active team"
            persist(manifest)
            return manifest
        }
        
        // 2. A pairing file must be available for the device.
        // Reuse the same lookup the boot flow uses.
        let hasPairing = AppBootManager.shared.getSavedPairingFile() != nil
        manifest.hasPairingFile = hasPairing
        guard hasPairing else {
            manifest.failureReason = "No pairing file"
            persist(manifest)
            return manifest
        }
        
        // 3. Minimuxer must report ready (this also runs transport selection).
        let readyResult = await isMinimuxerReady()
        switch readyResult {
        case .success(let ready):
            manifest.minimuxerReady = ready
            if !ready {
                manifest.failureReason = "Minimuxer not ready (transport unchecked)"
            }
        case .failure(let error):
            manifest.minimuxerReady = false
            manifest.failureReason = error.localizedDescription
        }
        
        persist(manifest)
        return manifest
    }
    
    private static func persist(_ manifest: RefreshVerificationManifest)
    {
        if let data = try? JSONEncoder().encode(manifest),
           let json = String(data: data, encoding: .utf8) {
            UserDefaults.standard.lastRefreshVerificationManifest = json
        }
    }
    
    static func loadLast() -> RefreshVerificationManifest?
    {
        guard let json = UserDefaults.standard.lastRefreshVerificationManifest,
              let data = json.data(using: .utf8) else { return nil }
        return try? JSONDecoder().decode(RefreshVerificationManifest.self, from: data)
    }
}
