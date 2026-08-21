//
//  InsetGroupTableViewCell.swift
//  AltStore
//
//  Created by Riley Testut on 8/31/19.
//  Copyright © 2019 Riley Testut. All rights reserved.
//

@preconcurrency import UIKit

extension InsetGroupTableViewCell
{
    @objc enum Style: Int
    {
        case single
        case top
        case middle
        case bottom
    }
}

final class InsetGroupTableViewCell: UITableViewCell
{
#if !TARGET_INTERFACE_BUILDER
    @IBInspectable var style: Style = .single {
        didSet {
            self.update()
        }
    }
#else
    @IBInspectable var style: Int = 0
#endif
    
    @IBInspectable var isSelectable: Bool = false
    
    private let separatorView = UIView()
    private let insetView = UIView()
    
    override func awakeFromNib()
    {
        super.awakeFromNib()
        
        self.selectionStyle = .none
        self.preservesSuperviewLayoutMargins = false
        self.contentView.preservesSuperviewLayoutMargins = false
        self.insetsLayoutMarginsFromSafeArea = false
        self.contentView.insetsLayoutMarginsFromSafeArea = false
        self.updateContentMargins()
        
        self.separatorView.translatesAutoresizingMaskIntoConstraints = false
        self.separatorView.backgroundColor = UIColor.separator
        self.addSubview(self.separatorView)
        
        self.insetView.layer.masksToBounds = true
        self.insetView.layer.cornerRadius = 20
        self.insetView.layer.borderWidth = 1.0
        self.insetView.layer.borderColor = UIColor.separator.withAlphaComponent(0.2).cgColor
        
        // Get the preferred background color from Interface Builder.
        self.insetView.backgroundColor = .secondarySystemGroupedBackground
        self.backgroundColor = nil
        
        self.insetView.translatesAutoresizingMaskIntoConstraints = false
        self.addSubview(self.insetView)
        self.sendSubviewToBack(self.insetView)
        
        NSLayoutConstraint.activate([self.insetView.leadingAnchor.constraint(equalTo: self.safeAreaLayoutGuide.leadingAnchor, constant: 16),
                                     self.insetView.trailingAnchor.constraint(equalTo: self.safeAreaLayoutGuide.trailingAnchor, constant: -16),
                                     self.insetView.topAnchor.constraint(equalTo: self.topAnchor),
                                     self.insetView.bottomAnchor.constraint(equalTo: self.bottomAnchor),
                                     self.separatorView.leadingAnchor.constraint(equalTo: self.safeAreaLayoutGuide.leadingAnchor, constant: 30),
                                     self.separatorView.trailingAnchor.constraint(equalTo: self.safeAreaLayoutGuide.trailingAnchor, constant: -30),
                                     self.separatorView.bottomAnchor.constraint(equalTo: self.bottomAnchor),
                                     self.separatorView.heightAnchor.constraint(equalToConstant: 1)])
        
        self.update()
    }

    override func safeAreaInsetsDidChange()
    {
        super.safeAreaInsetsDidChange()
        self.updateContentMargins()
    }
    
    override func setSelected(_ selected: Bool, animated: Bool)
    {
        super.setSelected(selected, animated: animated)
        
        if animated
        {
            UIView.animate(withDuration: 0.4) {
                self.update()
            }
        }
        else
        {
            self.update()
        }
    }
    
    override func setHighlighted(_ highlighted: Bool, animated: Bool)
    {
        super.setHighlighted(highlighted, animated: animated)
        
        let scale: CGFloat = highlighted ? 0.97 : 1.0
        UIView.animate(withDuration: 0.18, delay: 0, usingSpringWithDamping: 0.7, initialSpringVelocity: 0.5, options: [.allowUserInteraction]) {
            self.insetView.transform = CGAffineTransform(scaleX: scale, y: scale)
            self.update()
        }
    }
}

private extension InsetGroupTableViewCell
{
    func updateContentMargins()
    {
        self.contentView.layoutMargins = UIEdgeInsets(
            top: self.layoutMargins.top,
            left: self.safeAreaInsets.left + 30,
            bottom: self.layoutMargins.bottom,
            right: self.safeAreaInsets.right + 30
        )
    }

    func update()
    {
        switch self.style
        {
        case .single:
            self.insetView.layer.maskedCorners = [.layerMinXMinYCorner, .layerMaxXMinYCorner, .layerMinXMaxYCorner, .layerMaxXMaxYCorner]
            self.separatorView.isHidden = true
            
        case .top:
            self.insetView.layer.maskedCorners = [.layerMinXMinYCorner, .layerMaxXMinYCorner]
            self.separatorView.isHidden = true
            
        case .middle:
            self.insetView.layer.maskedCorners = []
            self.separatorView.isHidden = true
            
        case .bottom:
            self.insetView.layer.maskedCorners = [.layerMinXMaxYCorner, .layerMaxXMaxYCorner]
            self.separatorView.isHidden = true
        }
        
        if self.isSelectable && (self.isHighlighted || self.isSelected)
        {
            self.insetView.backgroundColor = UIColor.systemFill
        }
        else
        {
            self.insetView.backgroundColor = UIColor.secondarySystemGroupedBackground
        }
    }
}
