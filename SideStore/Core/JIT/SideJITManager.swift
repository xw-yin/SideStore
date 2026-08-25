//
//  SideJITManager.swift
//  SideStore
//
//  Created by Magesh K on 14/8/26.
//  Copyright © 2026 SideStore. All rights reserved.
//

import UIKit

public final class SideJITManager {
    public static let shared = SideJITManager()
    
    private init() {}
    
    public func resolveServerURL() async -> String {
        if let address = UserDefaults.standard.textInputSideJITServerurl, !address.isEmpty {
            return address
        }
        
        if let resolved = await BonjourDiscoveryManagerV2.resolveFirstService(
            ofType: AppConstants.SideJIT.bonjourServiceType,
            namePrefix: AppConstants.SideJIT.bonjourServiceName,
            timeout: AppConstants.SideJIT.timeout
        ) {
            let cleanHost = resolved.host.strippingInterfaceScope
            let url = "http://\(cleanHost):\(resolved.port)"
            debugLog("[SideJITManager] Discovered SideJITServer via Bonjour at: \(url)")
            return url
        }
        
        return AppConstants.SideJIT.defaultServerURL
    }
    
    public func askForNetwork() async {
        let SJSURL = await resolveServerURL()
        guard let url = URL(string: "\(SJSURL)/re/") else { return }
        do {
            var request = URLRequest(url: url)
            request.timeoutInterval = AppConstants.SideJIT.timeout
            
            try await withThrowingTaskGroup(of: Void.self) { group in
                group.addTask {
                    let (data, response) = try await URLSession.shared.data(for: request)
                    let status = (response as? HTTPURLResponse)?.statusCode ?? 200
                    debugLog("[SideJITManager] askForNetwork: received response from \(url) (status: \(status))")
                }
                group.addTask {
                    try await Task.sleep(nanoseconds: UInt64(AppConstants.SideJIT.timeout * 1_000_000_000))
                    throw URLError(.timedOut)
                }
                try await group.next()
                group.cancelAll()
            }
        } catch {
            debugLog("[SideJITManager] askForNetwork error: \(error)")
        }
    }

    public func isSideJITServerDetected() async throws {
        let SJSURL = await resolveServerURL()
        guard let url = URL(string: SJSURL) else { throw URLError(.badURL) }
        var request = URLRequest(url: url)
        request.timeoutInterval = AppConstants.SideJIT.timeout
        
        try await withThrowingTaskGroup(of: Void.self) { group in
            group.addTask {
                let (_, response) = try await URLSession.shared.data(for: request)
                let status = (response as? HTTPURLResponse)?.statusCode ?? 200
                debugLog("[SideJITManager] SideJITServer detected at \(url) (status: \(status))")
            }
            group.addTask {
                try await Task.sleep(nanoseconds: UInt64(AppConstants.SideJIT.timeout * 1_000_000_000))
                throw URLError(.timedOut)
            }
            try await group.next()
            group.cancelAll()
        }
    }
}

// MARK: - UI Extension
extension SideJITManager {
    @MainActor
    public func presentJITPrompt(presentingVC: UIViewController) {
        let alert = UIAlertController(
            title: "SideJITServer Detected",
            message: "Would you like to enable SideJITServer",
            preferredStyle: .alert
        )
        alert.addAction(UIAlertAction(title: "OK", style: .default) { _ in UserDefaults.standard.isSideJITServerEnabled = true })
        alert.addAction(UIAlertAction(title: "Cancel", style: .cancel))
        presentingVC.present(alert, animated: true)
    }
}
