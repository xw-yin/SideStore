//
//  RefreshAttemptsViewController.swift
//  AltStore
//
//  Created by Riley Testut on 7/31/19.
//  Copyright © 2019 Riley Testut. All rights reserved.
//

@preconcurrency import UIKit
import CoreData

@objc(RefreshAttemptTableViewCell)
private final class RefreshAttemptTableViewCell: UITableViewCell
{
    @IBOutlet var successLabel: UILabel!
    @IBOutlet var dateLabel: UILabel!
    @IBOutlet var errorDescriptionLabel: UILabel!
}

final class RefreshAttemptsViewController: UITableViewController
{
    private lazy var dataSource = self.makeDataSource()
    
    private lazy var dateFormatter: DateFormatter = {
        let dateFormatter = DateFormatter()
        dateFormatter.dateStyle = .short
        dateFormatter.timeStyle = .short
        return dateFormatter
    }()
    
    override func viewDidLoad()
    {
        super.viewDidLoad()
        
        self.title = NSLocalizedString("Refresh Attempts", comment: "")
        self.navigationItem.largeTitleDisplayMode = .always
        
        let clearButton = UIBarButtonItem(image: UIImage(systemName: "trash"), style: .plain, target: self, action: #selector(clearRefreshAttempts(_:)))
        clearButton.accessibilityLabel = NSLocalizedString("Delete All", comment: "")
        self.navigationItem.rightBarButtonItem = clearButton
        
        self.tableView.dataSource = self.dataSource
        self.dataSource.contentView = self.tableView
    }
    
    @objc
    private func clearRefreshAttempts(_ sender: UIBarButtonItem)
    {
        #if os(tvOS)
        let style: UIAlertController.Style = .alert
        #else
        let style: UIAlertController.Style = .actionSheet
        #endif
        let alertController = UIAlertController(title: NSLocalizedString("Are you sure you want to delete all refresh attempts?", comment: ""), message: nil, preferredStyle: style)
        alertController.popoverPresentationController?.barButtonItem = sender
        alertController.addAction(.cancel)
        alertController.addAction(UIAlertAction(title: NSLocalizedString("Delete All", comment: ""), style: .destructive) { _ in
            Task {
                await self.deleteAllRefreshAttempts()
            }
        })
        self.present(alertController, animated: true)
    }
    
    private func deleteAllRefreshAttempts() async
    {
        do
        {
            try await DatabaseManager.shared.purgeRefreshAttempts()
        }
        catch
        {
            let alertController = UIAlertController(
                title: NSLocalizedString("Failed to Delete Refresh Attempts", comment: ""),
                message: error.localizedDescription,
                preferredStyle: .alert
            )
            alertController.addAction(.ok)
            self.present(alertController, animated: true)
        }
    }
}

extension RefreshAttemptsViewController
{
    #if !os(tvOS)
    override func tableView(_ tableView: UITableView, trailingSwipeActionsConfigurationForRowAt indexPath: IndexPath) -> UISwipeActionsConfiguration?
    {
        let deleteAction = UIContextualAction(style: .destructive, title: NSLocalizedString("Delete", comment: "")) { _, _, completion in
            let attempt = self.dataSource.item(at: indexPath)
            DatabaseManager.shared.persistentContainer.performBackgroundTask { context in
                do
                {
                    let attempt = context.object(with: attempt.objectID) as! RefreshAttempt
                    context.delete(attempt)
                    
                    try context.save()
                    DispatchQueue.main.async {
                        completion(true)
                    }
                }
                catch
                {
                    debugLog("[SideStore] Failed to delete RefreshAttempt \(attempt.objectID): \(error)")
                    DispatchQueue.main.async {
                        completion(false)
                    }
                }
            }
        }
        
        let configuration = UISwipeActionsConfiguration(actions: [deleteAction])
        configuration.performsFirstActionWithFullSwipe = false
        return configuration
    }
    #endif
}

private extension RefreshAttemptsViewController
{
    func makeDataSource() -> FetchedResultsTableViewDataSource<RefreshAttempt>
    {
        let fetchRequest = RefreshAttempt.fetchRequest() as NSFetchRequest<RefreshAttempt>
        fetchRequest.sortDescriptors = [NSSortDescriptor(keyPath: \RefreshAttempt.date, ascending: false)]
        fetchRequest.returnsObjectsAsFaults = false
        
        let dataSource = FetchedResultsTableViewDataSource(fetchRequest: fetchRequest, managedObjectContext: DatabaseManager.shared.viewContext)
        dataSource.cellConfigurationHandler = { [weak self] (cell, attempt, indexPath) in
            let cell = cell as! RefreshAttemptTableViewCell
            cell.dateLabel.text = self?.dateFormatter.string(from: attempt.date)
            cell.errorDescriptionLabel.text = attempt.errorDescription
            
            if attempt.isSuccess
            {
                cell.successLabel.text = NSLocalizedString("Success", comment: "")
                cell.successLabel.textColor = .refreshGreen
            }
            else
            {
                cell.successLabel.text = NSLocalizedString("Failure", comment: "")
                cell.successLabel.textColor = .refreshRed
            }
        }
        
        let placeholderView = PlaceholderView()
        placeholderView.textLabel.text = NSLocalizedString("No Refresh Attempts", comment: "")
        placeholderView.detailTextLabel.text = NSLocalizedString("The more you use SideStore, the more often iOS will allow it to refresh apps in the background.", comment: "")
        dataSource.placeholderView = placeholderView
        
        return dataSource
    }
}
