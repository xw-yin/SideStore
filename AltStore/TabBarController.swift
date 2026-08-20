//
//  TabBarController.swift
//  AltStore
//
//  Created by Riley Testut on 9/19/19.
//  Copyright © 2019 Riley Testut. All rights reserved.
//

@preconcurrency import UIKit

extension TabBarController
{
    private enum Tab: Int, CaseIterable
    {
        case news
        case sources
        case browse
        case myApps
        case settings
    }
}

final class TabBarController: UITabBarController
{
    private var initialSegue: (identifier: String, sender: Any?)?
    private var embeddedVersionLabel: UILabel?
    
    private var _viewDidAppear = false
    
    private var sourcesViewController: SourcesViewController!
    
    required init?(coder aDecoder: NSCoder)
    {
        super.init(coder: aDecoder)
        
        NotificationCenter.default.addObserver(self, selector: #selector(TabBarController.importApp(_:)), name: AppDelegate.importAppDeepLinkNotification, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(TabBarController.presentSources(_:)), name: AppDelegate.addSourceDeepLinkNotification, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(TabBarController.openErrorLog(_:)), name: ToastView.openErrorLogNotification, object: nil)
    }
    
    override func viewDidLoad() 
    {
        super.viewDidLoad()
        debugLog("[TabBarController] viewDidLoad()")
        
        guard let viewControllers = self.viewControllers else {
            debugLog("[TabBarController] No child view controllers were loaded from Main.storyboard")
            return
        }

        if viewControllers.indices.contains(Tab.browse.rawValue) {
            viewControllers[Tab.browse.rawValue].tabBarItem.image = UIImage(systemName: "bag")
        }

        if viewControllers.indices.contains(Tab.sources.rawValue),
           let sourcesNavigationController = viewControllers[Tab.sources.rawValue] as? UINavigationController {
            self.sourcesViewController = sourcesNavigationController.viewControllers.first as? SourcesViewController
        }
        
        let titles: [Tab: String] = [
            .news: NSLocalizedString("News", comment: ""),
            .sources: NSLocalizedString("Sources", comment: ""),
            .browse: NSLocalizedString("Browse", comment: ""),
            .myApps: NSLocalizedString("My Apps", comment: ""),
            .settings: NSLocalizedString("Settings", comment: "")
        ]
        for (tab, title) in titles {
            guard viewControllers.indices.contains(tab.rawValue) else {
                debugLog("[TabBarController] Missing storyboard tab at index \(tab.rawValue)")
                continue
            }
            viewControllers[tab.rawValue].tabBarItem.title = title
        }

        self.configureEmbeddedVersionLabel()
    }
    
    override func viewDidAppear(_ animated: Bool)
    {
        super.viewDidAppear(animated)
        debugLog("[TabBarController] viewDidAppear() — TabBarController is now visible")
        
        _viewDidAppear = true
        
        if let (identifier, sender) = self.initialSegue
        {
            self.initialSegue = nil
            self.performSegue(withIdentifier: identifier, sender: sender)
        }
    }
    
    override func performSegue(withIdentifier identifier: String, sender: Any?)
    {
        guard _viewDidAppear else {
            self.initialSegue = (identifier, sender)
            return
        }
        
        super.performSegue(withIdentifier: identifier, sender: sender)
    }
}

extension TabBarController
{
    @objc func presentSources(_ sender: Any)
    {
        if let presentedViewController = self.presentedViewController
        {
            presentedViewController.dismiss(animated: true) {
                self.presentSources(sender)
            }
            
            return
        }
                
        if let notification = (sender as? Notification), let sourceURL = notification.userInfo?[AppDelegate.addSourceDeepLinkURLKey] as? URL
        {
            self.sourcesViewController?.deepLinkSourceURL = sourceURL
        }
        
        selectTab(.sources)
    }
}

private extension TabBarController
{
    @objc func importApp(_ notification: Notification)
    {
        selectTab(.myApps)
    }

    @objc func openErrorLog(_ notification: Notification)
    {
        selectTab(.settings)
    }
}

private extension TabBarController
{
    func configureEmbeddedVersionLabel()
    {
        guard Bundle.isBundledWithLiveContainer, self.embeddedVersionLabel == nil else { return }

        let liveContainerInfo = Bundle.realMainBundle.infoDictionary
        let liveContainerVersion = liveContainerInfo?["CFBundleShortVersionString"] as? String ?? "?"
        let liveContainerBuild = liveContainerInfo?["LCVersionInfo"] as? String ?? "?"
        let sideStoreVersion = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "?"

        let versionLabel = UILabel()
        versionLabel.translatesAutoresizingMaskIntoConstraints = false
        versionLabel.font = .systemFont(ofSize: 9, weight: .regular)
        versionLabel.textColor = .secondaryLabel
        versionLabel.textAlignment = .center
        versionLabel.isUserInteractionEnabled = false
        versionLabel.text = "LC \(liveContainerVersion)-\(liveContainerBuild), SS \(sideStoreVersion)"

        self.view.addSubview(versionLabel)
        NSLayoutConstraint.activate([
            versionLabel.centerXAnchor.constraint(equalTo: self.view.safeAreaLayoutGuide.centerXAnchor),
            versionLabel.bottomAnchor.constraint(equalTo: self.view.safeAreaLayoutGuide.bottomAnchor, constant: 13)
        ])
        self.embeddedVersionLabel = versionLabel
    }
}

private extension TabBarController
{
    private func selectTab(_ tab: Tab)
    {
        guard let viewControllers, viewControllers.indices.contains(tab.rawValue) else {
            debugLog("[TabBarController] Cannot select missing tab at index \(tab.rawValue)")
            return
        }
        self.selectedIndex = tab.rawValue
    }
}
