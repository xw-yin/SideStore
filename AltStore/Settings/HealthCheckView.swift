//
//  HealthCheckView.swift
//  AltStore
//
//  Created by Magesh K on 11/07/26.
//  Copyright © 2026 SideStore. All rights reserved.
//

import SwiftUI
import Minimuxer
import Darwin

struct LocalInterfaceInfo: Hashable, Identifiable {
    var id: String { name + "-" + ip }
    let name: String
    let ip: String
    let subnet: String
    let type: String
}

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
        let readyResult = await Minimuxer.shared.isReady()
        let scanned = self.scanLocalInterfaces()
        
        return HealthCheckMetrics(
            connectionMode: mode,
            wifi: wifi, wired: wired, usb: usb, bridge: bridge, utun: utun, ipsec: ipsec,
            tunnelIfaceIp: tunnelIfaceIp, tunnelIfaceSubnetMask: tunnelIfaceSubnetMask, tunnelPeerIp: tunnelPeerIp,
            overrideTunnelPeerIp: overrideTunnelPeerIp, overrideTunnelPeerEffective: overrideTunnelPeerEffective,
            remoteServerIp: remoteServerIp, remotePeerIp: remotePeerIp, remoteReachable: remoteReachable,
            protocolStr: protocolStr, pingSuccess: pingSuccess,
            ddi: ddi, pairingVerified: pairingVerified, readyResult: readyResult, scanned: scanned
        )
    }

    func pollMetrics() async {
        while !Task.isCancelled {
            if UIApplication.shared.applicationState == .active {
                // Hop to background thread to perform all synchronous FFI/network checks
                let metrics = await self.fetchMetrics()
                
                let status = self.computeStatuses(metrics)
                
                // Update UI back on Main Actor
                self.updateUI(metrics: metrics, status: status)
            }
            
            try? await Task.sleep(nanoseconds: 1_000_000_000)
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
            case .noVPN, .invalidVPN:
                return (netSat, false, nil, nil, nil, nil)
            case .noDevice, .notReachable:
                pingSat = false
                pairingSat = nil
                ddiSat = nil
            case .pairingFile, .invalidPairing:
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

struct HealthCheckView: View {
    @StateObject private var viewModel = HealthCheckViewModel()
    
    var body: some View {
        List {
            // Section 1: Connection Status Header
            Section {
                VStack(spacing: 12) {
                    if let result = viewModel.minimuxerReadyResult {
                        switch result {
                        case .success:
                            Image(systemName: "checkmark.circle.fill")
                                .font(.system(size: 44))
                                .foregroundColor(.green)
                            Text("SideStore Ready")
                                .font(.title2)
                                .fontWeight(.bold)
                            Text(viewModel.connectionMode == .localVPN
                                 ? "All requirements met. Local device pairing & VPN tunnel active."
                                 : "All requirements met. Local device pairing & Remote server connection active."
                            )
                            .font(.subheadline)
                            .foregroundColor(.secondary)
                            .multilineTextAlignment(.center)
                        case .failure(let err):
                            Image(systemName: "exclamationmark.triangle.fill")
                                .font(.system(size: 44))
                                .foregroundColor(.orange)
                            Text("Action Required")
                                .font(.title2)
                                .fontWeight(.bold)
                            Text(err.localizedDescription)
                                .font(.subheadline)
                                .foregroundColor(.secondary)
                                .multilineTextAlignment(.center)
                        }
                    } else {
                        ProgressView("Performing Diagnostic Check...")
                    }
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 8)
            }
            
            // Section 2: Core Dependencies
            Section(header: Text("Core Requirements")) {
                DependencyRow(
                    title: "Network Connectivity",
                    subtitle: viewModel.isWifiSatisfied ? "Wi-Fi Active" : "No Connection",
                    isSatisfied: viewModel.networkSatisfied
                )
                
                if viewModel.connectionMode == .localVPN {
                    DependencyRow(
                        title: "VPN Tunnel (utun)",
                        subtitle: viewModel.isUTunAvailable ? "Connected" : "Disconnected",
                        isSatisfied: viewModel.vpnSatisfied
                    )
                    
                    if !Minimuxer.shared.isrppairing {
                        if #available(iOS 26.4, *) {
                            DependencyRow(
                                title: "IPSec/IKEv2 Tunnel",
                                subtitle: viewModel.isIKEv2IPSecAvailable ? "Connected" : "Disconnected",
                                isSatisfied: viewModel.ipsecSatisfied
                            )
                        }
                    }
                }
                
                DependencyRow(
                    title: "Device Reachability (Ping)",
                    subtitle: viewModel.isPingSuccessful ? "Reachable" : "Unreachable",
                    isSatisfied: viewModel.pingSatisfied
                )
                
                DependencyRow(
                    title: "Pairing file",
                    subtitle: viewModel.isPairingFileVerified ? "Verified" : (Minimuxer.shared.isPairingFileLoaded ? "Loaded (Connection down)" : "Unverified / Missing"),
                    isSatisfied: viewModel.pairingSatisfied
                )
                
                DependencyRow(
                    title: "Developer Disk Image (DDI)",
                    subtitle: viewModel.isDDIMounted ? "Mounted" : "Not Mounted",
                    isSatisfied: viewModel.ddiSatisfied
                )
            }
            
            // Section 3: Connection Configuration
            Section(header: Text("Connection Configuration")) {
                HStack {
                    Text("Connection Mode")
                    Spacer()
                    Text(viewModel.connectionMode == .localVPN ? "Local VPN" : "Remote Server")
                        .foregroundColor(.secondary)
                }
                
                if viewModel.connectionMode == .localVPN {
                    ConfigRow(label: "Tunnel Iface IP", value: viewModel.tunnelIfaceIp)
                    ConfigRow(label: "Tunnel Subnet Mask", value: viewModel.tunnelIfaceSubnetMask)
                    ConfigRow(label: "Tunnel Peer IP", value: viewModel.tunnelPeerIp)
                    ConfigRow(label: "Override Peer IP", value: viewModel.overrideTunnelPeerIp.isEmpty ? nil : viewModel.overrideTunnelPeerIp)
                    HStack {
                        Text("Override Status")
                        Spacer()
                        Text(viewModel.overrideTunnelPeerEffective ? "Active" : "Inactive")
                            .foregroundColor(viewModel.overrideTunnelPeerEffective ? .green : .secondary)
                    }
                    HStack {
                        Text("Active Protocol")
                        Spacer()
                        Text(viewModel.activeProtocol)
                            .foregroundColor(.secondary)
                    }
                } else {
                    ConfigRow(label: "Remote Endpoint IP", value: viewModel.remoteServerIp.isEmpty ? nil : viewModel.remoteServerIp)
                    HStack {
                        Text("Active Protocol")
                        Spacer()
                        Text(viewModel.activeProtocol)
                            .foregroundColor(.secondary)
                    }
                }
            }
            
            // Section 4: All Active Interfaces
            Section(header: Text("Active Network Interfaces")) {
                if viewModel.availableInterfaces.isEmpty {
                    Text("No active interfaces scanned.")
                        .foregroundColor(.secondary)
                        .italic()
                } else {
                    let vpnInterfaces = viewModel.availableInterfaces.filter { $0.type.contains("VPN") }
                    let localInterfaces = viewModel.availableInterfaces.filter { !$0.type.contains("VPN") }
                    
                    if !vpnInterfaces.isEmpty {
                        ForEach(vpnInterfaces) { iface in
                            InterfaceRow(iface: iface)
                        }
                    }
                    
                    if !localInterfaces.isEmpty {
                        ForEach(localInterfaces) { iface in
                            InterfaceRow(iface: iface)
                        }
                    }
                }
            }
        }
        .navigationTitle("Health Check")
        .navigationBarTitleDisplayMode(.inline)
        .task {
            await viewModel.pollMetrics()
        }
    }
}

struct DependencyRow: View {
    let title: String
    let subtitle: String
    let isSatisfied: Bool?
    
    var body: some View {
        HStack {
            VStack(alignment: .leading, spacing: 4) {
                Text(title)
                    .font(.body)
                Text(subtitle)
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
            Spacer()
            if let satisfied = isSatisfied {
                Image(systemName: satisfied ? "checkmark.circle.fill" : "xmark.circle.fill")
                    .foregroundColor(satisfied ? .green : .red)
                    .font(.title3)
            } else {
                Image(systemName: "questionmark.circle.fill")
                    .foregroundColor(.gray)
                    .font(.title3)
            }
        }
    }
}

struct ConfigRow: View {
    let label: String
    let value: String?
    
    var body: some View {
        HStack {
            Text(label)
            Spacer()
            Text(value ?? "N/A")
                .foregroundColor(.secondary)
        }
    }
}

struct InterfaceRow: View {
    let iface: LocalInterfaceInfo
    
    var body: some View {
        HStack {
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 8) {
                    Text(iface.name)
                        .fontWeight(.semibold)
                    Text(iface.type)
                        .font(.caption)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(iface.type.contains("VPN") ? Color.blue.opacity(0.15) : Color.gray.opacity(0.15))
                        .foregroundColor(iface.type.contains("VPN") ? .blue : .primary)
                        .cornerRadius(4)
                }
                Text("Subnet: \(iface.subnet)")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
            Spacer()
            Text(iface.ip)
                .font(.system(.body, design: .monospaced))
                .foregroundColor(.secondary)
        }
    }
}
