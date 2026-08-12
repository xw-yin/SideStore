//
//  EMProxyWrapper.swift
//  SideStore
//
//  Created by Magesh K on 22/02/26.
//  Copyright © 2026 SideStore. All rights reserved.
//

import Foundation
import Minimuxer

enum EMProxyError: LocalizedError {
    case invalidSocketAddress(String)
    
    var errorDescription: String? {
        switch self {
        case .invalidSocketAddress(let addr):
            return "Invalid socket address: \(addr)"
        }
    }
}

func startEMProxy(bind_addr: String = AppConstants.Proxy.serverURL) async throws {
    debugLog("[SideStore] startEMProxy(\(bind_addr)) invoked")
    defer { debugLog("[SideStore] startEMProxy() completed") }

    #if targetEnvironment(simulator)
    debugLog("[SideStore] startEMProxy() is no-op on simulator")
    #else
    let components = bind_addr.split(separator: ":")
    guard components.count >= 1 && components.count <= 2 else {
        debugLog("[SideStore] startEMProxy() invalid bind_addr format: \(bind_addr)")
        throw EMProxyError.invalidSocketAddress(bind_addr)
    }

    debugLog("[SideStore] startEMProxy() running in standard minimuxer mode")
    #endif
}

func stopEMProxy() async throws {
    debugLog("[SideStore] stopEMProxy() invoked")
    defer { debugLog("[SideStore] stopEMProxy() completed") }

    #if targetEnvironment(simulator)
    debugLog("[SideStore] stopEMProxy() is no-op on simulator")
    #else
    debugLog("[SideStore] stopEMProxy() completed")
    #endif
}
