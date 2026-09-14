//
//  UICollectionView+CellContent.swift
//  AltStore
//
//  Created by Magesh K on 8/9/26.
//  Copyright © 2026 SideStore. All rights reserved.
//

@preconcurrency import UIKit

extension UICollectionView: CellContentUpdateableView, CellContentTransactionUpdateable {
    private struct AssociatedKeys {
        static var nestedUpdatesCounter: UInt8 = 0
        static var operations: UInt8 = 0
    }

    private var nestedUpdatesCounter: Int {
        get { objc_getAssociatedObject(self, &AssociatedKeys.nestedUpdatesCounter) as? Int ?? 0 }
        set { objc_setAssociatedObject(self, &AssociatedKeys.nestedUpdatesCounter, newValue, .OBJC_ASSOCIATION_COPY_NONATOMIC) }
    }

    private var operations: [CellContentChange]? {
        get { objc_getAssociatedObject(self, &AssociatedKeys.operations) as? [CellContentChange] }
        set { objc_setAssociatedObject(self, &AssociatedKeys.operations, newValue, .OBJC_ASSOCIATION_RETAIN_NONATOMIC) }
    }

    public func beginUpdates() {
        if nestedUpdatesCounter == 0 {
            operations = []
        }
        nestedUpdatesCounter += 1
    }

    public func endUpdates() {
        guard nestedUpdatesCounter > 0 else { return }
        nestedUpdatesCounter -= 1
        
        if nestedUpdatesCounter > 0 {
            return
        }
        
        guard let currentOperations = operations else { return }
        operations = nil
        
        // Check for conflicts to prevent UIKit crashes
        var hasConflict = false
        
        var deletedSections = Set<Int>()
        var insertedSections = Set<Int>()
        var hasSectionChanges = false
        var hasItemChanges = false
        
        var deletedItems = Set<IndexPath>()
        var insertedItems = Set<IndexPath>()
        var updatedItems = Set<IndexPath>()
        var movedItems = Set<IndexPath>()
        
        for change in currentOperations {
            if change.sectionIndex != UnknownSectionIndex {
                hasSectionChanges = true
                if change.type == .delete {
                    deletedSections.insert(change.sectionIndex)
                } else if change.type == .insert {
                    insertedSections.insert(change.sectionIndex)
                }
            } else {
                hasItemChanges = true
                
                if change.type == .delete, let ip = change.currentIndexPath {
                    if deletedItems.contains(ip) || movedItems.contains(ip) || updatedItems.contains(ip) {
                        hasConflict = true
                        break
                    }
                    deletedItems.insert(ip)
                } else if change.type == .insert, let ip = change.destinationIndexPath {
                    if insertedItems.contains(ip) || movedItems.contains(ip) {
                        hasConflict = true
                        break
                    }
                    insertedItems.insert(ip)
                } else if change.type == .update, let ip = change.currentIndexPath {
                    if updatedItems.contains(ip) || deletedItems.contains(ip) || movedItems.contains(ip) {
                        hasConflict = true
                        break
                    }
                    updatedItems.insert(ip)
                } else if change.type == .move, let src = change.currentIndexPath, let dest = change.destinationIndexPath {
                    if movedItems.contains(src) || deletedItems.contains(src) || updatedItems.contains(src) {
                        hasConflict = true
                        break
                    }
                    if movedItems.contains(dest) || insertedItems.contains(dest) {
                        hasConflict = true
                        break
                    }
                    movedItems.insert(src)
                    movedItems.insert(dest)
                }
            }
        }
        
        // Conflict if we have both section changes and item changes in the same batch
        if hasSectionChanges && hasItemChanges {
            hasConflict = true
        }
        
        // Conflict if an item change falls inside a deleted or inserted section
        if !hasConflict {
            for ip in deletedItems.union(insertedItems).union(updatedItems).union(movedItems) {
                if deletedSections.contains(ip.section) || insertedSections.contains(ip.section) {
                    hasConflict = true
                    break
                }
            }
        }
        
        if hasConflict {
            self.reloadData()
            return
        }
        
        var postMoveUpdateChanges = [CellContentChange]()
        for change in currentOperations {
            if change.type == .move, let destinationIndexPath = change.destinationIndexPath {
                let updateChange = CellContentChange(type: .update, currentIndexPath: destinationIndexPath, destinationIndexPath: nil)
                updateChange.rowAnimation = change.rowAnimation
                postMoveUpdateChanges.append(updateChange)
            }
        }
        
        var updateIndexPaths = [IndexPath]()
        for change in currentOperations {
            if change.sectionIndex == UnknownSectionIndex && change.type == .update, let indexPath = change.currentIndexPath {
                updateIndexPaths.append(indexPath)
            }
        }
        
        let moveIndexPaths = postMoveUpdateChanges.compactMap { $0.currentIndexPath }
        let allTargetIndexPaths = Array(Set(updateIndexPaths + moveIndexPaths))
        
        var isFinished = false
        let finish = { [weak self] in
            guard let self = self, !isFinished else { return }
            isFinished = true
            
            if !allTargetIndexPaths.isEmpty {
                UIView.performWithoutAnimation {
                    self.reconfigureItems(at: allTargetIndexPaths)
                }
            }
        }
        
        CATransaction.begin()
        CATransaction.setCompletionBlock {
            finish()
        }
        
        self.performBatchUpdates({
            for change in currentOperations {
                if change.sectionIndex != UnknownSectionIndex {
                    let indexSet = IndexSet(integer: change.sectionIndex)
                    switch change.type {
                    case .insert: self.insertSections(indexSet)
                    case .delete: self.deleteSections(indexSet)
                    case .update: self.reloadSections(indexSet)
                    default: break
                    }
                } else {
                    switch change.type {
                    case .insert:
                        if let destinationIndexPath = change.destinationIndexPath {
                            self.insertItems(at: [destinationIndexPath])
                        }
                    case .delete:
                        if let currentIndexPath = change.currentIndexPath {
                            self.deleteItems(at: [currentIndexPath])
                        }
                    case .update:
                        break
                    case .move:
                        if let currentIndexPath = change.currentIndexPath, let destinationIndexPath = change.destinationIndexPath {
                            self.moveItem(at: currentIndexPath, to: destinationIndexPath)
                        }
                    }
                }
            }
        }, completion: { _ in
            finish()
        })
        
        CATransaction.commit()
    }

    public func addChange(_ change: CellContentChange) {
        if nestedUpdatesCounter > 0 {
            operations?.append(change)
        } else {
            self.performBatchUpdates({
                if change.sectionIndex != UnknownSectionIndex {
                    let indexSet = IndexSet(integer: change.sectionIndex)
                    switch change.type {
                    case .insert: self.insertSections(indexSet)
                    case .delete: self.deleteSections(indexSet)
                    case .update: self.reloadSections(indexSet)
                    default: break
                    }
                } else {
                    switch change.type {
                    case .insert:
                        if let destinationIndexPath = change.destinationIndexPath { self.insertItems(at: [destinationIndexPath]) }
                    case .delete:
                        if let currentIndexPath = change.currentIndexPath { self.deleteItems(at: [currentIndexPath]) }
                    case .update:
                        if let currentIndexPath = change.currentIndexPath {
                            UIView.performWithoutAnimation {
                                self.reconfigureItems(at: [currentIndexPath])
                            }
                        }
                    case .move:
                        if let currentIndexPath = change.currentIndexPath, let destinationIndexPath = change.destinationIndexPath {
                            self.moveItem(at: currentIndexPath, to: destinationIndexPath)
                            UIView.performWithoutAnimation {
                                self.reconfigureItems(at: [destinationIndexPath])
                            }
                        }
                    }
                }
            }, completion: nil)
        }
    }
}

public extension UICollectionView {
    func add(_ change: CellContentChange) {
        self.addChange(change)
    }
}
