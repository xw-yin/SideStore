//
//  ConnectionConfig.swift
//  AltStore
//
//  Created by Magesh K on 02/03/26.
//  Copyright © 2026 SideStore. All rights reserved.
//

import SwiftUI
import Combine

final class ConnectionConfig: ObservableObject {
    static let shared = ConnectionConfig()

    private static let defaultOverrideIP: String = "10.7.0.1"
    private static let defaultRemoteServerIP: String = "10.7.0.1"

    @Published var tunnelIfaceIp: String?
    @Published var tunnelIfaceSubnetMask: String?
    @Published var tunnelPeerIp: String?
    @Published var overrideTunnelPeerIp: String = overrideIPStorage {
        didSet { Self.overrideIPStorage = overrideTunnelPeerIp }
    }
    @Published var overrideTunnelPeerReachable: Bool = false

    @Published var remoteServerIp: String = remoteServerIPStorage {
        didSet { Self.remoteServerIPStorage = remoteServerIp }
    }
    @Published var remotePeerIp: String?
    @Published var remoteReachable: Bool = false

    @Published var useLocalVPN: Bool = useLocalVPNStorage {
        didSet { Self.useLocalVPNStorage = useLocalVPN }
    }

    private static var overrideIPStorage: String {
        get { UserDefaults.standard.string(forKey: "TunnelOverridePeerIp") ?? defaultOverrideIP }
        set { UserDefaults.standard.set(newValue, forKey: "TunnelOverridePeerIp") }
    }

    private static var remoteServerIPStorage: String {
        get { UserDefaults.standard.string(forKey: "RemoteServerIp") ?? defaultRemoteServerIP }
        set { UserDefaults.standard.set(newValue, forKey: "RemoteServerIp") }
    }

    private static var useLocalVPNStorage: Bool {
        get { UserDefaults.standard.useLocalVPN }
        set { UserDefaults.standard.useLocalVPN = newValue }
    }

    var overrideTunnelPeerActive: ActiveState { overrideTunnelPeerReachable ? .yes : .no }
    var remoteActive: ActiveState { remoteReachable ? .yes : .no }
}
