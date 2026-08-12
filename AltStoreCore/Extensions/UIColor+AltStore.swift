//
//  UIColor+AltStore.swift
//  AltStore
//
//  Created by Riley Testut on 5/9/19.
//  Copyright © 2019 Riley Testut. All rights reserved.
//

@preconcurrency import UIKit

public extension UIColor
{
    private static let colorBundle = Bundle(for: DatabaseManager.self)
    
    static var altPrimary: UIColor {
        return ThemeManager.shared.primaryColor
    }
    static let defaultAltPrimary = UIColor(named: "Primary", in: colorBundle, compatibleWith: nil)!
    static let deltaPrimary = UIColor(named: "DeltaPrimary", in: colorBundle, compatibleWith: nil)
    static let clipPrimary = UIColor(named: "ClipPrimary", in: colorBundle, compatibleWith: nil)
    
    static let refreshRed = UIColor(named: "RefreshRed", in: colorBundle, compatibleWith: nil)!
    static let refreshOrange = UIColor(named: "RefreshOrange", in: colorBundle, compatibleWith: nil)!
    static let refreshYellow = UIColor(named: "RefreshYellow", in: colorBundle, compatibleWith: nil)!
    static let refreshGreen = UIColor(named: "RefreshGreen", in: colorBundle, compatibleWith: nil)!
}
