//
//  NewsViewController.swift
//  AltStore
//
//  Created by Riley Testut on 8/29/19.
//  Copyright © 2019 Riley Testut. All rights reserved.
//

@preconcurrency import UIKit
import SafariServices
import Combine
import CoreData
@preconcurrency import AltStoreCore

import Nuke

private final class AppBannerFooterView: UICollectionReusableView
{
    let bannerView = AppBannerView(frame: .zero)
    let tapGestureRecognizer = UITapGestureRecognizer(target: nil, action: nil)
    
    override init(frame: CGRect)
    {
        super.init(frame: frame)
        
        self.addGestureRecognizer(self.tapGestureRecognizer)
        
        self.bannerView.translatesAutoresizingMaskIntoConstraints = false
        self.addSubview(self.bannerView)
        
        NSLayoutConstraint.activate([
            self.bannerView.topAnchor.constraint(equalTo: self.topAnchor),
            self.bannerView.bottomAnchor.constraint(equalTo: self.bottomAnchor),
            self.bannerView.leadingAnchor.constraint(equalTo: self.layoutMarginsGuide.leadingAnchor),
            self.bannerView.trailingAnchor.constraint(equalTo: self.layoutMarginsGuide.trailingAnchor)
        ])
    }
    
    required init?(coder aDecoder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }
}

class NewsViewController: UICollectionViewController, PeekPopPreviewing
{
    // Nil == Show news from all sources.
    var source: Source?
    
    private lazy var dataSource = self.makeDataSource()
    private lazy var placeholderView = RSTPlaceholderView(frame: .zero)
    private var retryButton: UIButton!
    
    private var prototypeCell: NewsCollectionViewCell!
    
    // Cache
    private var cachedCellSizes = [String: CGSize]()
    private var cancellables = Set<AnyCancellable>()
    
    init?(source: Source?, coder: NSCoder)
    {
        self.source = source
        
        super.init(coder: coder)
        
        self.initialize()
    }
    
    required init?(coder: NSCoder)
    {
        super.init(coder: coder)
        
        self.initialize()
    }
    
    private func initialize()
    {
        NotificationCenter.default.addObserver(self, selector: #selector(NewsViewController.importApp(_:)), name: AppDelegate.importAppDeepLinkNotification, object: nil)
    }
    
    override func viewDidLoad()
    {
        super.viewDidLoad()
        
        self.collectionView.backgroundColor = .altBackground

        // Ignore the safe area for horizontal layout so cards sit symmetrically
        // from the physical screen edge; top/bottom insets are managed manually
        // in viewWillLayoutSubviews().
        self.collectionView.contentInsetAdjustmentBehavior = .never

        if let layout = self.collectionView.collectionViewLayout as? UICollectionViewFlowLayout
        {
            layout.sectionInsetReference = .fromContentInset
            layout.sectionInset.left = 16
            layout.sectionInset.right = 16
            layout.estimatedItemSize = .zero
        }
        
        self.prototypeCell = NewsCollectionViewCell.instantiate(with: NewsCollectionViewCell.nib)
        self.prototypeCell.contentView.translatesAutoresizingMaskIntoConstraints = false
        
        // Need to add dummy constraint + layout subviews before we can remove Interface Builder's width constraint.
        self.prototypeCell.widthAnchor.constraint(greaterThanOrEqualToConstant: 0).isActive = true
        self.prototypeCell.layoutIfNeeded()
        
        let constraints = self.prototypeCell.constraintsAffectingLayout(for: .horizontal)
        for constraint in constraints where constraint.identifier?.contains("Encapsulated-Layout-Width") == true
        {
            self.prototypeCell.removeConstraint(constraint)
        }
        
        self.collectionView.dataSource = self.dataSource
        self.collectionView.prefetchDataSource = self.dataSource
        self.dataSource.contentView = self.collectionView
        
        self.collectionView.register(NewsCollectionViewCell.nib, forCellWithReuseIdentifier: RSTCellContentGenericCellIdentifier)
        self.collectionView.register(AppBannerFooterView.self, forSupplementaryViewOfKind: UICollectionView.elementKindSectionFooter, withReuseIdentifier: "AppBanner")
        
        (self as PeekPopPreviewing).registerForPreviewing(with: self, sourceView: self.collectionView)
        
        let refreshControl = UIRefreshControl(frame: .zero)
        refreshControl.addTarget(self, action: #selector(NewsViewController.updateSources), for: .primaryActionTriggered)
        self.collectionView.refreshControl = refreshControl
        
        self.retryButton = UIButton(type: .system)
        self.retryButton.titleLabel?.font = UIFont.preferredFont(forTextStyle: .body)
        self.retryButton.setTitle(NSLocalizedString("Try Again", comment: ""), for: .normal)
        self.retryButton.addTarget(self, action: #selector(NewsViewController.updateSources), for: .primaryActionTriggered)
        self.placeholderView.stackView.addArrangedSubview(self.retryButton)
        
        if let source = self.source
        {
            let tintColor = source.effectiveTintColor ?? .altPrimary
            self.view.tintColor = tintColor
            
            let appearance = NavigationBarAppearance()
            appearance.configureWithTintColor(tintColor)
            appearance.configureWithDefaultBackground()
            
            let edgeAppearance = appearance.copy()
            edgeAppearance.configureWithTransparentBackground()
            
            self.navigationItem.standardAppearance = appearance
            self.navigationItem.scrollEdgeAppearance = edgeAppearance
        }
        
        self.preparePipeline()
        self.update()
    }

    override func viewWillLayoutSubviews()
    {
        super.viewWillLayoutSubviews()

        // contentInsetAdjustmentBehavior is .never, so apply the vertical safe-area
        // insets manually (keeping the original 20pt bottom padding). Horizontal
        // insets are intentionally left at zero so content spans the full width.
        let safeArea = self.collectionView.safeAreaInsets
        let bottomInset = safeArea.bottom + 20
        if self.collectionView.contentInset.top != safeArea.top || self.collectionView.contentInset.bottom != bottomInset
        {
            // Triggers collection view update in iOS 13, which crashes if we do it in viewDidLoad()
            // since the database might not be loaded yet.
            self.collectionView.contentInset.top = safeArea.top
            self.collectionView.contentInset.bottom = bottomInset
        }
    }
    
    override func viewWillTransition(to size: CGSize, with coordinator: UIViewControllerTransitionCoordinator)
    {
        super.viewWillTransition(to: size, with: coordinator)

        coordinator.animate(alongsideTransition: nil) { [weak self] _ in
            self?.cachedCellSizes.removeAll()
            self?.collectionView.collectionViewLayout.invalidateLayout()
        }
    }
}

private extension NewsViewController
{
    func preparePipeline()
    {
        AppManager.shared.$updateSourcesResult
            .receive(on: RunLoop.main) // Delay to next run loop so we receive _current_ value (not previous value).
            .sink { result in
                self.update()
            }
            .store(in: &self.cancellables)
    }
    
    func makeDataSource() -> RSTFetchedResultsCollectionViewPrefetchingDataSource<NewsItem, UIImage>
    {
        let fetchRequest = NewsItem.sortedFetchRequest(for: self.source)
        let context = self.source?.managedObjectContext ?? DatabaseManager.shared.viewContext
        
        // Use fetchedResultsController to split NewsItems up into sections.
        let fetchedResultsController = NSFetchedResultsController(fetchRequest: fetchRequest, managedObjectContext: context, sectionNameKeyPath: #keyPath(NewsItem.objectID), cacheName: nil)
        
        let dataSource = RSTFetchedResultsCollectionViewPrefetchingDataSource<NewsItem, UIImage>(fetchedResultsController: fetchedResultsController)
        dataSource.proxy = self
        dataSource.cellConfigurationHandler = { [weak self] (cell, newsItem, indexPath) in
            guard let self else { return }
            
            let cell = cell as! NewsCollectionViewCell
            
            cell.preservesSuperviewLayoutMargins = false
            cell.contentView.preservesSuperviewLayoutMargins = false
            cell.insetsLayoutMarginsFromSafeArea = false
            cell.contentView.insetsLayoutMarginsFromSafeArea = false
            cell.layoutMargins = .zero
            cell.contentView.layoutMargins = .zero
            
            cell.titleLabel.text = newsItem.title
            cell.captionLabel.text = newsItem.caption
            cell.contentBackgroundView.backgroundColor = newsItem.tintColor
            
            cell.imageView.image = nil
            
            let aspectConstraint = cell.imageView.constraints.first(where: {
                ($0.firstAttribute == .width && $0.secondAttribute == .height) ||
                ($0.firstAttribute == .height && $0.secondAttribute == .width)
            })
            if newsItem.imageURL != nil
            {
                cell.imageView.isIndicatingActivity = true
                cell.imageView.isHidden = false
                aspectConstraint?.priority = UILayoutPriority(999)
            }
            else
            {
                cell.imageView.isIndicatingActivity = false
                cell.imageView.isHidden = true
                aspectConstraint?.priority = UILayoutPriority(250)
            }
            
            cell.isAccessibilityElement = true
            cell.accessibilityLabel = (cell.titleLabel.text ?? "") + ". " + (cell.captionLabel.text ?? "")
            
            if newsItem.storeApp != nil || newsItem.externalURL != nil
            {
                cell.accessibilityTraits.insert(.button)
            }
            else
            {
                cell.accessibilityTraits.remove(.button)
            }
        }
        dataSource.prefetchHandler = { (newsItem, indexPath, completionHandler) in
            guard let imageURL = newsItem.imageURL else { return nil }
            
            Task.detached(priority: .background) {
                ImagePipeline.shared.loadImage(with: imageURL, progress: nil) { result in
                    switch result
                    {
                    case .success(let response): completionHandler(response.image, nil)
                    case .failure(let error): completionHandler(nil, error)
                    }
                }
            }
            return nil
        }
        dataSource.prefetchCompletionHandler = { (cell, image, indexPath, error) in
            let cell = cell as! NewsCollectionViewCell
            cell.imageView.isIndicatingActivity = false
            cell.imageView.image = image
            
            if let error = error
            {
                debugLog("Error loading image: \(error)")
            }
        }
        
        dataSource.placeholderView = self.placeholderView
        
        return dataSource
    }
    
    @objc func updateSources()
    {
        AppManager.shared.updateAllSources() { result in
            self.collectionView.refreshControl?.endRefreshing()
            
            guard case .failure(let error) = result else { return }
            
            if self.dataSource.itemCount > 0
            {
                let toastView = ToastView(error: error)
                toastView.addTarget(nil, action: #selector(TabBarController.presentSources), for: .touchUpInside)
                toastView.show(in: self)
            }
        }
    }
    
    func update()
    {
        switch AppManager.shared.updateSourcesResult
        {
        case nil:
            self.placeholderView.textLabel.isHidden = true
            self.placeholderView.detailTextLabel.isHidden = false
            
            self.placeholderView.detailTextLabel.text = NSLocalizedString("Loading...", comment: "")
            
            self.retryButton.isHidden = true
            self.placeholderView.activityIndicatorView.startAnimating()
            
        case .failure(let error):
            self.placeholderView.textLabel.isHidden = false
            self.placeholderView.detailTextLabel.isHidden = false
            
            self.placeholderView.textLabel.text = NSLocalizedString("Unable to Fetch News", comment: "")
            self.placeholderView.detailTextLabel.text = error.localizedDescription
            
            self.retryButton.isHidden = false
            self.placeholderView.activityIndicatorView.stopAnimating()
            
        case .success:
            self.placeholderView.textLabel.isHidden = true
            self.placeholderView.detailTextLabel.isHidden = true
            
            self.retryButton.isHidden = true
            self.placeholderView.activityIndicatorView.stopAnimating()
        }
    }
}

private extension NewsViewController
{
    @objc func handleTapGesture(_ gestureRecognizer: UITapGestureRecognizer)
    {
        guard let footerView = gestureRecognizer.view as? UICollectionReusableView else { return }
        
        let indexPaths = self.collectionView.indexPathsForVisibleSupplementaryElements(ofKind: UICollectionView.elementKindSectionFooter)
        
        guard let indexPath = indexPaths.first(where: { (indexPath) -> Bool in
            let supplementaryView = self.collectionView.supplementaryView(forElementKind: UICollectionView.elementKindSectionFooter, at: indexPath)
            return supplementaryView == footerView
        }) else { return }
        
        let item = self.dataSource.item(at: indexPath)
        guard let storeApp = item.storeApp else { return }
        
        let appViewController = AppViewController.makeAppViewController(app: storeApp)
        self.navigationController?.pushViewController(appViewController, animated: true)
    }
    
    @objc func performAppAction(_ sender: PillButton)
    {
        let point = self.collectionView.convert(sender.center, from: sender.superview)
        let indexPaths = self.collectionView.indexPathsForVisibleSupplementaryElements(ofKind: UICollectionView.elementKindSectionFooter)
        
        guard let indexPath = indexPaths.first(where: { (indexPath) -> Bool in
            let supplementaryView = self.collectionView.supplementaryView(forElementKind: UICollectionView.elementKindSectionFooter, at: indexPath)
            return supplementaryView?.frame.contains(point) ?? false
        }) else { return }
        
        let app = self.dataSource.item(at: indexPath)
        guard let storeApp = app.storeApp else { return }
        
        // if let installedApp = storeApp.installedApp, !installedApp.isUpdateAvailable
        if let installedApp = storeApp.installedApp, !installedApp.hasUpdate
        {
            self.open(installedApp)
        }
        else
        {
            self.install(storeApp, at: indexPath) { progress in
                sender.progress = progress
            }
        }
    }
    
    func install(_ storeApp: StoreApp, at indexPath: IndexPath, progressUpdateHandler: @escaping (Progress) -> Void)
    {
        let previousProgress = AppManager.shared.installationProgress(for: storeApp)
        guard previousProgress == nil else {
            previousProgress?.cancel()
            return
        }
        
        Task(priority: .userInitiated) { @MainActor in
            // if let installedApp = storeApp.installedApp, installedApp.isUpdateAvailable
            if let installedApp = storeApp.installedApp, installedApp.hasUpdate
            {
                let progress = AppManager.shared.update(installedApp, presentingViewController: self, completionHandler: finish(_:))
                progressUpdateHandler(progress)
            }
            else
            {
                let group = await AppManager.shared.installAsync(storeApp, presentingViewController: self, completionHandler: finish(_:))
                progressUpdateHandler(group.progress)
            }
        }
        
        @MainActor
        func finish(_ result: Result<InstalledApp, Error>)
        {
            DispatchQueue.main.async {
                switch result
                {
                case .failure(let error) where error is CancellationError: break // Ignore
                case .failure(let error):
                    let toastView = ToastView(error: error)
                    toastView.opensErrorLog = true
                    toastView.show(in: self)

                case .success: debugLog("Installed app: \(storeApp.bundleIdentifier)")
                }
                
                UIView.performWithoutAnimation {
                    self.collectionView.reloadSections(IndexSet(integer: indexPath.section))
                }
            }
        }
    }
    
    func open(_ installedApp: InstalledApp)
    {
        UIApplication.shared.open(installedApp.openAppURL)
    }
}

private extension NewsViewController
{
    @objc func importApp(_ notification: Notification)
    {
        self.presentedViewController?.dismiss(animated: true, completion: nil)
    }
}

extension NewsViewController
{
    override func collectionView(_ collectionView: UICollectionView, didSelectItemAt indexPath: IndexPath)
    {
        let newsItem = self.dataSource.item(at: indexPath)
        
        if let externalURL = newsItem.externalURL
        {
            let safariViewController = SFSafariViewController(url: externalURL)
            safariViewController.preferredControlTintColor = newsItem.tintColor
            self.present(safariViewController, animated: true, completion: nil)
        }
        else if let storeApp = newsItem.storeApp
        {
            let appViewController = AppViewController.makeAppViewController(app: storeApp)
            self.navigationController?.pushViewController(appViewController, animated: true)
        }
    }
    
    override func collectionView(_ collectionView: UICollectionView, viewForSupplementaryElementOfKind kind: String, at indexPath: IndexPath) -> UICollectionReusableView
    {
        let item = self.dataSource.item(at: indexPath)
        
        let footerView = collectionView.dequeueReusableSupplementaryView(ofKind: UICollectionView.elementKindSectionFooter, withReuseIdentifier: "AppBanner", for: indexPath) as! AppBannerFooterView
        guard let storeApp = item.storeApp else { return footerView }
        
        footerView.insetsLayoutMarginsFromSafeArea = false
        footerView.layoutMargins.left = 16
        footerView.layoutMargins.right = 16
        
        footerView.bannerView.button.isIndicatingActivity = false
        footerView.bannerView.configure(for: storeApp)
        
        footerView.bannerView.tintColor = storeApp.tintColor
        footerView.bannerView.button.addTarget(self, action: #selector(NewsViewController.performAppAction(_:)), for: .primaryActionTriggered)
        footerView.tapGestureRecognizer.addTarget(self, action: #selector(NewsViewController.handleTapGesture(_:)))
        
        Nuke.loadImage(with: storeApp.iconURL, into: footerView.bannerView.iconImageView) { result in
            footerView.bannerView.iconImageView.isIndicatingActivity = false
        }
        
        return footerView
    }
}

extension NewsViewController: UICollectionViewDelegateFlowLayout
{
    func collectionView(_ collectionView: UICollectionView, layout collectionViewLayout: UICollectionViewLayout, sizeForItemAt indexPath: IndexPath) -> CGSize
    {        
        let item = self.dataSource.item(at: indexPath)
        let globallyUniqueID = item.globallyUniqueID ?? item.identifier
        let contentWidth = self.cardContentWidth(in: collectionView)
        let layoutWidth = Int(contentWidth.rounded())
        let cacheKey = "\(globallyUniqueID)-\(layoutWidth)"
        
        if let previousSize = self.cachedCellSizes[cacheKey]
        {
            return previousSize
        }
        
        self.prototypeCell.frame.size.width = contentWidth
        self.prototypeCell.layoutMargins = .zero
        self.prototypeCell.contentView.layoutMargins = .zero
        self.prototypeCell.layoutIfNeeded()
        
        let widthConstraint = self.prototypeCell.contentView.widthAnchor.constraint(equalToConstant: contentWidth)
        widthConstraint.isActive = true
        defer { widthConstraint.isActive = false }
        
        self.dataSource.cellConfigurationHandler(self.prototypeCell, item, indexPath)
        
        var size = self.prototypeCell.contentView.systemLayoutSizeFitting(UIView.layoutFittingCompressedSize)
        size.width = contentWidth
        self.cachedCellSizes[cacheKey] = size
        return size
    }
    
    func collectionView(_ collectionView: UICollectionView, layout collectionViewLayout: UICollectionViewLayout, referenceSizeForFooterInSection section: Int) -> CGSize
    {
        guard self.dataSource.contentView(collectionView, numberOfItemsInSection: section) > 0 else {
            return .zero
        }
        
        let item = self.dataSource.item(at: IndexPath(row: 0, section: section))
        
        if item.storeApp != nil
        {
            return CGSize(width: self.cardContentWidth(in: collectionView), height: 88)
        }
        else
        {
            return .zero
        }
    }
    
    func collectionView(_ collectionView: UICollectionView, layout collectionViewLayout: UICollectionViewLayout, insetForSectionAt section: Int) -> UIEdgeInsets
    {
        var insets = UIEdgeInsets(top: 30, left: 16, bottom: 13, right: 16)
        
        if section == 0
        {
            insets.top = 10
        }
        
        return insets
    }

    private func cardContentWidth(in collectionView: UICollectionView) -> CGFloat
    {
        return max(1, collectionView.bounds.width - 32)
    }
}

extension NewsViewController: UIViewControllerPreviewingDelegate
{
    @available(iOS, deprecated: 13.0)
    func previewingContext(_ previewingContext: UIViewControllerPreviewing, viewControllerForLocation location: CGPoint) -> UIViewController?
    {
        if let indexPath = self.collectionView.indexPathForItem(at: location), let cell = self.collectionView.cellForItem(at: indexPath)
        {
            // Previewing news item.
            
            previewingContext.sourceRect = cell.frame
            
            let newsItem = self.dataSource.item(at: indexPath)
            
            if let externalURL = newsItem.externalURL
            {
                let safariViewController = SFSafariViewController(url: externalURL)
                safariViewController.preferredControlTintColor = newsItem.tintColor
                return safariViewController
            }
            else if let storeApp = newsItem.storeApp
            {
                let appViewController = AppViewController.makeAppViewController(app: storeApp)
                return appViewController
            }
            
            return nil
        }
        else
        {
            // Previewing app banner (or nothing).
            
            let indexPaths = self.collectionView.indexPathsForVisibleSupplementaryElements(ofKind: UICollectionView.elementKindSectionFooter)
            
            guard let indexPath = indexPaths.first(where: { (indexPath) -> Bool in
                let layoutAttributes = self.collectionView.layoutAttributesForSupplementaryElement(ofKind: UICollectionView.elementKindSectionFooter, at: indexPath)
                return layoutAttributes?.frame.contains(location) ?? false
            }) else { return nil }
            
            guard let layoutAttributes = self.collectionView.layoutAttributesForSupplementaryElement(ofKind: UICollectionView.elementKindSectionFooter, at: indexPath) else { return nil }
            previewingContext.sourceRect = layoutAttributes.frame
            
            let item = self.dataSource.item(at: indexPath)
            guard let storeApp = item.storeApp else { return nil }
            
            let appViewController = AppViewController.makeAppViewController(app: storeApp)
            return appViewController
        }
    }
    
    @available(iOS, deprecated: 13.0)
    func previewingContext(_ previewingContext: UIViewControllerPreviewing, commit viewControllerToCommit: UIViewController)
    {
        if let safariViewController = viewControllerToCommit as? SFSafariViewController
        {
            self.present(safariViewController, animated: true, completion: nil)
        }
        else
        {
            self.navigationController?.pushViewController(viewControllerToCommit, animated: true)
        }
    }
}
