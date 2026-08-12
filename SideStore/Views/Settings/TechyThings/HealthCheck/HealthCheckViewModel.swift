//
//  HealthCheckViewModel.swift
//  SideStore
//
//  Created by Magesh K on 11/07/26.
//  Copyright © 2026 SideStore. All rights reserved.
//

import SwiftUI
import Minimuxer
import Darwin
import Combine

/*
 Minimuxer.shared.isReady Result Mapping to Core Requirements Statuses:
 
 | Ready Result Case                        | Network   | VPN       | IPSec     | Ping      | Pairing   | DDI       |
 | ---------------------------------------- | --------- | --------- | --------- | --------- | --------- | --------- |
 | .success                                 | Satisfied | Satisfied | Satisfied | Satisfied | Satisfied | Satisfied |
 | .failure(.noConnection)                  | Failed    | Unknown   | Unknown   | Unknown   | Unknown   | Unknown   |
 | .failure(.noVPN) / .failure(.invalidVPN) | Satisfied | Failed    | Unknown   | Unknown   | Unknown   | Unknown   |
 | .failure(.pairingFile)                   | Satisfied | Satisfied | Satisfied | Satisfied | Failed    | Unknown   |
 | .failure(.invalidPairing)                | Satisfied | Satisfied | Satisfied | Satisfied | Failed    | Unknown   |
 | .failure(.mount)                         | Satisfied | Satisfied | Satisfied | Satisfied | Satisfied | Failed    |
 | .failure(.muxerNotListening)             | Satisfied | Satisfied | Satisfied | Satisfied | Satisfied | Satisfied |
 */

@MainActor
final class HealthCheckViewModel: ObservableObject {
    @Published var isWifiSatisfied = false
    @Published var isWiredSatisfied = false
    @Published var isUsbSatisfied = false
    @Published var isBridgeSatisfied = false
    @Published var connectionMode: DeviceConnectionMode = .localVPN
    @Published var isUTunAvailable = false
    @Published var isIKEv2IPSecAvailable = false
    
    @Published var tunnelIfaceIp: String? = nil
    @Published var tunnelIfaceSubnetMask: String? = nil
    @Published var tunnelPeerIp: String? = nil
    @Published var overrideTunnelPeerIp: String = ""
    @Published var overrideTunnelPeerEffective = false
    @Published var remoteServerIp: String = ""
    @Published var remotePeerIp: String? = nil
    @Published var remoteReachable = false
    
    @Published var activeProtocol = ""
    @Published var isPingSuccessful = false
    
    @Published var isDDIMounted = false
    @Published var isPairingFileVerified = false
    @Published var isRPPairing = false
    @Published var isPairingFileLoaded = false
    
    @Published var networkSatisfied: Bool? = nil
    @Published var vpnSatisfied: Bool? = nil
    @Published var ipsecSatisfied: Bool? = nil
    @Published var pingSatisfied: Bool? = nil
    @Published var pairingSatisfied: Bool? = nil
    @Published var ddiSatisfied: Bool? = nil
    
    @Published var minimuxerReadyResult: Result<Bool, MinimuxerError>? = nil
    @Published var availableInterfaces: [LocalInterfaceInfo] = []

    struct HealthCheckMetrics {
        let connectionMode: DeviceConnectionMode
        let wifi: Bool
        let wired: Bool
        let usb: Bool
        let bridge: Bool
        let utun: Bool
        let ipsec: Bool
        let tunnelIfaceIp: String?
        let tunnelIfaceSubnetMask: String?
        let tunnelPeerIp: String?
        let overrideTunnelPeerIp: String?
        let overrideTunnelPeerEffective: Bool
        let remoteServerIp: String
        let remotePeerIp: String?
        let remoteReachable: Bool
        let protocolStr: String
        let pingSuccess: Bool
        let ddi: Bool
        let pairingVerified: Bool
        let isRpPairing: Bool
        let isPairingLoaded: Bool
        let readyResult: Result<Bool, MinimuxerError>
        let scanned: [LocalInterfaceInfo]
    }

    nonisolated private func fetchMetrics() async -> HealthCheckMetrics {
        let mode = await Minimuxer.shared.getConnectionMode()
        let wifi = Minimuxer.network.isWifiSatisfied
        let wired = Minimuxer.network.isWiredSatisfied
        let usb = Minimuxer.network.isUsbSatisfied
        let bridge = Minimuxer.network.isBridgeSatisfied
        let utun = Minimuxer.network.isUTunAvailable
        let ipsec = Minimuxer.network.isIKEv2IPSecAvailable
        
        let tunnelIfaceIp = ConnectionConfig.shared.tunnelIfaceIp
        let tunnelIfaceSubnetMask = ConnectionConfig.shared.tunnelIfaceSubnetMask
        let tunnelPeerIp = ConnectionConfig.shared.tunnelPeerIp
        let overrideTunnelPeerIp = ConnectionConfig.shared.overrideTunnelPeerIp
        let overrideTunnelPeerEffective = ConnectionConfig.shared.overrideTunnelPeerReachable
        let remoteServerIp = ConnectionConfig.shared.remoteServerIp
        let remotePeerIp = ConnectionConfig.shared.remotePeerIp
        let remoteReachable = ConnectionConfig.shared.remoteReachable
        
        let pairingType = Minimuxer.shared.getPairingFileType()
        let protocolStr: String
        switch pairingType {
        case .rppairing:
            protocolStr = "Remote Pairing"
        case .lockdown:
            protocolStr = "Lockdown"
        case .unknown:
            protocolStr = "Unknown"
        }
        
        let targetIp = mode == .localVPN ? (overrideTunnelPeerEffective ? overrideTunnelPeerIp : (tunnelPeerIp ?? "")) : remoteServerIp
        let pingSuccess = !targetIp.isEmpty && Minimuxer.shared.testDeviceConnection(ifaddr: targetIp)
        
        let ddi = (try? await Minimuxer.shared.isDDIMounted()) ?? false
        let pairingVerified = (try? await Minimuxer.shared.fetchUDID() != nil) ?? false
        let isRpPairing = Minimuxer.shared.isrppairing
        let isPairingLoaded = Minimuxer.shared.isPairingFileLoaded
        let readyResult = await Minimuxer.shared.isReady()
        let scanned = self.scanLocalInterfaces()
        
        return HealthCheckMetrics(
            connectionMode: mode,
            wifi: wifi, wired: wired, usb: usb, bridge: bridge, utun: utun, ipsec: ipsec,
            tunnelIfaceIp: tunnelIfaceIp, tunnelIfaceSubnetMask: tunnelIfaceSubnetMask, tunnelPeerIp: tunnelPeerIp,
            overrideTunnelPeerIp: overrideTunnelPeerIp, overrideTunnelPeerEffective: overrideTunnelPeerEffective,
            remoteServerIp: remoteServerIp, remotePeerIp: remotePeerIp, remoteReachable: remoteReachable,
            protocolStr: protocolStr, pingSuccess: pingSuccess,
            ddi: ddi, pairingVerified: pairingVerified, isRpPairing: isRpPairing, isPairingLoaded: isPairingLoaded,
            readyResult: readyResult, scanned: scanned
        )
    }

    func observeMetrics() async {
        // Perform initial diagnostics load
        let initialMetrics = await self.fetchMetrics()
        let initialStatus = self.computeStatuses(initialMetrics)
        self.updateUI(metrics: initialMetrics, status: initialStatus)
        
        // Listen to subsequent updates reactively
        for await _ in minimuxerStatusPublisher.values {
            guard !Task.isCancelled else { break }
            let metrics = await self.fetchMetrics()
            let status = self.computeStatuses(metrics)
            self.updateUI(metrics: metrics, status: status)
        }
    }
    
    typealias CoreRequirementStatuses = (
        netSat: Bool?,
        vpnSat: Bool?,
        ipsecSat: Bool?,
        pingSat: Bool?,
        pairingSat: Bool?,
        ddiSat: Bool?
    )

    nonisolated private func computeStatuses(
        _ m: HealthCheckMetrics
    ) -> CoreRequirementStatuses {
        let netSat = m.wifi
        let vpnSat = m.utun
        let isRp = m.protocolStr == "Remote Pairing"
        let ipsecSat = isRp ? nil : m.ipsec

        switch m.readyResult {
        case .success:
            let pingSat = m.pingSuccess
            let isPairingLoaded = Minimuxer.shared.isPairingFileLoaded
            let pairingSat: Bool? = m.pairingVerified ? true : (isPairingLoaded ? nil : false)
            let ddiSat = m.ddi
            return (netSat, vpnSat, ipsecSat, pingSat, pairingSat, ddiSat)

        case .failure(let error):
            var pingSat: Bool? = m.pingSuccess
            let isPairingLoaded = Minimuxer.shared.isPairingFileLoaded
            var pairingSat: Bool? = m.pairingVerified ? true : (isPairingLoaded ? nil : false)
            var ddiSat: Bool? = m.ddi

            switch error {
            case .noConnection:
                return (false, nil, nil, nil, nil, nil)
            case .notStarted, .pairingNotLoaded:
                return (nil, nil, nil, nil, nil, nil)
            case .noVPN, .invalidVPN:
                return (netSat, false, nil, nil, nil, nil)
            case .noDevice, .notReachable:
                pingSat = false
                pairingSat = nil
                ddiSat = nil
            case .invalidPairing:
                pairingSat = false
                ddiSat = nil
            case .mount:
                ddiSat = false
            case .muxerNotListening:
                break
            default:
                break
            }

            return (netSat, vpnSat, ipsecSat, pingSat, pairingSat, ddiSat)
        }
    }
    
    @MainActor
    func updateUI(metrics: HealthCheckMetrics, status: CoreRequirementStatuses) {
        self.connectionMode = metrics.connectionMode
        self.isWifiSatisfied = metrics.wifi
        self.isWiredSatisfied = metrics.wired
        self.isUsbSatisfied = metrics.usb
        self.isBridgeSatisfied = metrics.bridge
        self.isUTunAvailable = metrics.utun
        self.isIKEv2IPSecAvailable = metrics.ipsec
        
        self.tunnelIfaceIp = metrics.tunnelIfaceIp
        self.tunnelIfaceSubnetMask = metrics.tunnelIfaceSubnetMask
        self.tunnelPeerIp = metrics.tunnelPeerIp
        self.overrideTunnelPeerIp = metrics.overrideTunnelPeerIp ?? "N/A"
        self.overrideTunnelPeerEffective = metrics.overrideTunnelPeerEffective
        self.remoteServerIp = metrics.remoteServerIp
        self.remotePeerIp = metrics.remotePeerIp
        self.remoteReachable = metrics.remoteReachable
        
        self.activeProtocol = metrics.protocolStr
        self.isPingSuccessful = metrics.pingSuccess
        
        self.isDDIMounted = metrics.ddi
        self.isPairingFileVerified = metrics.pairingVerified
        self.isRPPairing = metrics.isRpPairing
        self.isPairingFileLoaded = metrics.isPairingLoaded
        
        self.networkSatisfied = status.netSat
        self.vpnSatisfied = status.vpnSat
        self.ipsecSatisfied = status.ipsecSat
        self.pingSatisfied = status.pingSat
        self.pairingSatisfied = status.pairingSat
        self.ddiSatisfied = status.ddiSat
        
        self.minimuxerReadyResult = metrics.readyResult
        self.availableInterfaces = metrics.scanned
    }

    
    nonisolated private func scanLocalInterfaces() -> [LocalInterfaceInfo] {
        var interfaces = [LocalInterfaceInfo]()
        var head: UnsafeMutablePointer<ifaddrs>? = nil
        guard getifaddrs(&head) == 0, let first = head else { return [] }
        defer { freeifaddrs(head) }
        
        var cur: UnsafeMutablePointer<ifaddrs>? = first
        while let p = cur {
            let e = p.pointee
            let flags = Int32(e.ifa_flags)
            
            let ipv4 = e.ifa_addr?.pointee.sa_family == UInt8(AF_INET)
            let active = (flags & (IFF_UP | IFF_RUNNING | IFF_LOOPBACK)) == (IFF_UP | IFF_RUNNING)
            
            if ipv4 && active {
                if let name = String(utf8String: e.ifa_name),
                   let addr = e.ifa_addr,
                   let mask = e.ifa_netmask {
                    
                    var hostBuf = [CChar](repeating: 0, count: Int(NI_MAXHOST))
                    var maskBuf = [CChar](repeating: 0, count: Int(NI_MAXHOST))
                    
                    if getnameinfo(addr, socklen_t(addr.pointee.sa_len), &hostBuf, socklen_t(hostBuf.count), nil, 0, NI_NUMERICHOST) == 0,
                       getnameinfo(mask, socklen_t(mask.pointee.sa_len), &maskBuf, socklen_t(maskBuf.count), nil, 0, NI_NUMERICHOST) == 0 {
                        
                        let ipStr = String(cString: hostBuf)
                        let maskStr = String(cString: maskBuf)
                        
                        let type: String
                        if name.hasPrefix("utun") {
                            type = "VPN (uTun)"
                        } else if name.hasPrefix("ipsec") {
                            type = "VPN (IPSec)"
                        } else if name.hasPrefix("en") {
                            type = "Wi-Fi / Ethernet"
                        } else if name.hasPrefix("pdp") {
                            type = "Cellular"
                        } else if name.hasPrefix("lo") {
                            type = "Loopback"
                        } else if name.hasPrefix("bridge") || name.hasPrefix("ap") {
                            type = "Bridge"
                        } else {
                            type = "Other"
                        }
                        
                        interfaces.append(LocalInterfaceInfo(name: name, ip: ipStr, subnet: maskStr, type: type))
                    }
                }
            }
            cur = e.ifa_next
        }
        
        return interfaces.sorted { $0.name.localizedCompare($1.name) == .orderedAscending }
    }
}
