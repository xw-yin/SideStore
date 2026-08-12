//
//  AppConstants.swift
//  SideStore
//
//  Created by Joseph Mattiello on 11/7/22.
//  Copyright © 2022 Riley Testut. All rights reserved.
//

import Foundation

public enum AppConstants {
    enum Proxy {
        static let address = "127.0.0.1"
        static let port = "51820"
        static let defaultPort: UInt16 = 51820
        static let serverURL = "\(address):\(port)"
    }
    
    public enum Connection {
        public static let defaultOverrideIP = "10.7.0.1"
        public static let defaultRemoteServerIP = "10.7.0.1"
    }
    
    public static let accountConfigurationFileName = "Account.sideconf"
}
