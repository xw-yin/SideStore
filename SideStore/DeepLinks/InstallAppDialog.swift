//
//  InstallAppDialog.swift
//  SideStore
//
//  Created by Magesh K on 8/2/26.
//  Copyright © 2026 SideStore. All rights reserved.
//

import UIKit

@MainActor
public enum InstallAppDialog {
    
    public static func present(
        ipaURL: URL,
        from presentingViewController: UIViewController? = nil,
        onConfirm: @escaping () -> Void,
        onCancel: @escaping () -> Void
    ) {
        let rootVC = presentingViewController ?? topViewController()
        guard let presentingVC = rootVC else {
            onCancel()
            return
        }
        
        let appName = ipaURL.deletingPathExtension().lastPathComponent
        
        let alert = UIAlertController(
            title: NSLocalizedString("Install App", comment: ""),
            message: String(format: NSLocalizedString("Would you like to install \"%@\"?", comment: ""), appName),
            preferredStyle: .alert
        )
        
        let installAction = UIAlertAction(title: NSLocalizedString("Install", comment: ""), style: .default) { _ in
            onConfirm()
        }
        
        let cancelAction = UIAlertAction(title: NSLocalizedString("Cancel", comment: ""), style: .cancel) { _ in
            onCancel()
        }
        
        alert.addAction(installAction)
        alert.addAction(cancelAction)
        
        presentingVC.present(alert, animated: true)
    }
    
    private static func topViewController(base: UIViewController? = UIApplication.shared.connectedScenes
        .compactMap { ($0 as? UIWindowScene)?.keyWindow }
        .first?.rootViewController) -> UIViewController? {
            
        if let nav = base as? UINavigationController {
            return topViewController(base: nav.visibleViewController)
        }
        if let tab = base as? UITabBarController {
            if let selected = tab.selectedViewController {
                return topViewController(base: selected)
            }
        }
        if let presented = base?.presentedViewController {
            return topViewController(base: presented)
        }
        return base
    }
}
