//
//  PillButton.swift
//  AltStore
//
//  Created by Riley Testut on 7/15/19.
//  Copyright © 2019 Riley Testut. All rights reserved.
//

@preconcurrency import UIKit
@preconcurrency import AltStoreCore

extension PillButton
{
    static let minimumSize = CGSize(width: 77, height: 31)
    static let contentInsets = NSDirectionalEdgeInsets(top: 7, leading: 13, bottom: 7, trailing: 13)
}

extension PillButton
{
    enum Style
    {
        case pill
        case custom
    }

    enum DisplayState
    {
        case active(title: String, daysRemaining: Int)
        case crossSigned(title: String, daysRemaining: Int)
        case expired
        case revoked
    }
}

class PillButton: UIButton
{
    override var accessibilityValue: String? {
        get {
            guard self.progress != nil else { return super.accessibilityValue }
            return self.progressView.accessibilityValue
        }
        set { super.accessibilityValue = newValue }
    }
    
    var progress: Progress? {
        didSet {
            self.progressView.progress = Float(self.progress?.fractionCompleted ?? 0)
            self.progressView.observedProgress = self.progress
            
            let isUserInteractionEnabled = self.isUserInteractionEnabled
            self.isIndicatingActivity = (self.progress != nil)
            if self.progress != nil
            {
                self.isUserInteractionEnabled = isUserInteractionEnabled
            }
            
            self.update()
        }
    }
    
    var progressTintColor: UIColor? {
        didSet {
            self.update()
        }
    }
    
    var borderColor: UIColor? {
        didSet {
            self.update()
        }
    }
    
    var borderWidth: CGFloat = 0 {
        didSet {
            self.update()
        }
    }
    
    var countdownDate: Date? {
        didSet {
            self.isEnabled = (self.countdownDate == nil)
            self.displayLink.isPaused = (self.countdownDate == nil)
            
            if self.countdownDate == nil
            {
                self.setTitle(nil, for: .disabled)
            }
        }
    }
    
    var style: Style = .pill {
        didSet {
            guard self.style != oldValue else { return }
            
            if self.style == .custom
            {
                // Reset insets for custom style.
                self.contentEdgeInsets = UIEdgeInsets(top: 8, left: 8, bottom: 8, right: 8)
            }
            
            self.update()
        }
    }
    
    var fontSize: CGFloat? {
        didSet {
            self.update()
        }
    }
    
    private var storyboardFontSize: CGFloat?
    
    private let progressView = UIProgressView(progressViewStyle: .default)
    
    private lazy var displayLink: CADisplayLink = {
        let displayLink = CADisplayLink(target: self, selector: #selector(PillButton.updateCountdown))
        displayLink.preferredFramesPerSecond = 15
        displayLink.isPaused = true
        displayLink.add(to: .main, forMode: .common)
        return displayLink
    }()
    
    private let dateComponentsFormatter: DateComponentsFormatter = {
        let dateComponentsFormatter = DateComponentsFormatter()
        dateComponentsFormatter.zeroFormattingBehavior = [.pad]
        dateComponentsFormatter.collapsesLargestUnit = false
        return dateComponentsFormatter
    }()
    
    override var intrinsicContentSize: CGSize {
        let size = self.sizeThatFits(CGSize(width: Double.infinity, height: .infinity))
        return size
    }
    
    deinit
    {
        self.displayLink.remove(from: .main, forMode: RunLoop.Mode.default)
    }
    
    override init(frame: CGRect)
    {
        super.init(frame: frame)
        
        self.initialize()
    }
    
    required init?(coder: NSCoder)
    {
        super.init(coder: coder)
    }
    
    override func awakeFromNib()
    {
        super.awakeFromNib()
        self.storyboardFontSize = self.titleLabel?.font.pointSize
        self.initialize()
    }
    
    private func initialize()
    {
        self.layer.masksToBounds = true
        self.accessibilityTraits.formUnion([.updatesFrequently, .button])
        
        self.activityIndicatorView.style = .medium
        self.activityIndicatorView.color = .white
        self.activityIndicatorView.isUserInteractionEnabled = false
        
        self.progressView.progress = 0
        self.progressView.trackImage = UIImage()
        self.progressView.isUserInteractionEnabled = false
        self.addSubview(self.progressView)
        
        self.update()
    }
    
    override func layoutSubviews()
    {
        super.layoutSubviews()
        
        self.progressView.bounds.size.width = self.bounds.width
        
        let scale = self.bounds.height / self.progressView.bounds.height
        
        self.progressView.transform = CGAffineTransform.identity.scaledBy(x: 1, y: scale)
        self.progressView.center = CGPoint(x: self.bounds.midX, y: self.bounds.midY)
        
        self.layer.cornerRadius = self.bounds.midY
    }
    
    override func tintColorDidChange()
    {
        super.tintColorDidChange()
        
        self.update()
    }
    
    override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent?) {
        super.touchesBegan(touches, with: event)
        UIView.animate(withDuration: 0.15, delay: 0, options: [.beginFromCurrentState, .allowUserInteraction], animations: {
            self.transform = CGAffineTransform(scaleX: 0.94, y: 0.94)
        }, completion: nil)
        
        let feedbackGenerator = UIImpactFeedbackGenerator(style: .light)
        feedbackGenerator.prepare()
        feedbackGenerator.impactOccurred()
    }
    
    override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent?) {
        super.touchesEnded(touches, with: event)
        UIView.animate(withDuration: 0.25, delay: 0, usingSpringWithDamping: 0.5, initialSpringVelocity: 1.0, options: [.beginFromCurrentState, .allowUserInteraction], animations: {
            self.transform = .identity
        }, completion: nil)
    }
    
    override func touchesCancelled(_ touches: Set<UITouch>, with event: UIEvent?) {
        super.touchesCancelled(touches, with: event)
        UIView.animate(withDuration: 0.25, delay: 0, usingSpringWithDamping: 0.5, initialSpringVelocity: 1.0, options: [.beginFromCurrentState, .allowUserInteraction], animations: {
            self.transform = .identity
        }, completion: nil)
    }
    
    override func sizeThatFits(_ size: CGSize) -> CGSize
    {
        var size = super.sizeThatFits(size)
        
        switch self.style 
        {
        case .pill:
            // Enforce minimum size for pill style.
            size.width = max(size.width, PillButton.minimumSize.width)
            size.height = max(size.height, PillButton.minimumSize.height)
            
        case .custom: break
        }
        
        return size
    }
}

extension PillButton {
    func configure(for installedApp: InstalledApp) {
        let currentDate = Date()
        let expirationDate = installedApp.expirationDate
        let isExpired = currentDate > expirationDate
        
        // verboseLog("[PillButton] configure for app '\(installedApp.name)': status=\(installedApp.certificateStatus), certSerial=\(installedApp.certificateSerialNumber ?? "nil"), isExpired=\(isExpired)")
        
        if installedApp.certificateStatus == .revoked {
            self.setDisplayState(.revoked)
        } else if isExpired || installedApp.certificateStatus == .expired {
            self.setDisplayState(.expired)
        } else {
            let formatter = DateComponentsFormatter()
            formatter.unitsStyle = .full
            formatter.allowedUnits = [.day, .hour, .minute]
            formatter.maximumUnitCount = 1
            let title = formatter.string(from: currentDate, to: expirationDate) ?? ""
            let days = Calendar.current.dateComponents([.day], from: currentDate, to: expirationDate).day ?? 0
            
            if case .valid(let isCrossSigned) = installedApp.certificateStatus, isCrossSigned {
                self.setDisplayState(.crossSigned(title: title, daysRemaining: days))
            } else {
                self.setDisplayState(.active(title: title, daysRemaining: days))
            }
        }
    }

    func resetDisplayState() {
        // verboseLog("[PillButton] resetDisplayState called")
        self.countdownDate = nil
        self.borderColor = nil
        self.borderWidth = 0
        self.progress = nil
        self.setTitle(nil, for: .normal)
        self.update()
    }

    func setDisplayState(_ state: DisplayState) {
        // verboseLog("[PillButton] setDisplayState called: \(state)")
        switch state {
        case .revoked:
            self.countdownDate = nil
            self.tintColor = .refreshRed
            self.borderColor = nil
            self.borderWidth = 0
            self.setTitle(NSLocalizedString("REVOKED", comment: ""), for: .normal)
            
        case .expired:
            self.countdownDate = nil
            self.tintColor = .refreshRed
            self.borderColor = nil
            self.borderWidth = 0
            self.setTitle(NSLocalizedString("EXPIRED", comment: ""), for: .normal)
            
        case .active(let title, let daysRemaining):
            self.setTitle(title.uppercased(), for: .normal)
            self.borderColor = nil
            self.borderWidth = 0
            
            switch daysRemaining {
            case 2...3: self.tintColor = .refreshOrange
            case 4...5: self.tintColor = .refreshYellow
            case 6...: self.tintColor = .refreshGreen
            default: self.tintColor = .refreshRed
            }
            
        case .crossSigned(let title, let daysRemaining):
            self.setTitle(title.uppercased(), for: .normal)
            self.borderColor = .systemBlue
            self.borderWidth = 2.0
            
            switch daysRemaining {
            case 2...3: self.tintColor = .refreshOrange
            case 4...5: self.tintColor = .refreshYellow
            case 6...: self.tintColor = .refreshGreen
            default: self.tintColor = .refreshRed
            }
        }
        self.update()
    }
}

private extension PillButton
{
    func update()
    {
        if self.progress == nil
        {
            self.setTitleColor(.white, for: .normal)
            self.backgroundColor = self.tintColor
            self.progressView.progressTintColor = self.progressTintColor ?? self.tintColor
            self.layer.borderColor = self.borderColor?.cgColor
            self.layer.borderWidth = self.borderWidth
        }
        else
        {
            self.setTitleColor(self.tintColor, for: .normal)
            self.backgroundColor = self.tintColor.withAlphaComponent(0.15)
            self.progressView.progressTintColor = self.progressTintColor ?? self.tintColor
            self.layer.borderColor = nil
            self.layer.borderWidth = 0
        }
        
//        verboseLog("[PillButton] update() applied: title='\(self.title(for: .normal) ?? "")', borderWidth=\(self.layer.borderWidth), hasBorderColor=\(self.layer.borderColor != nil), progressNil=\(self.progress == nil)")
        
        // Update font after init because the original titleLabel is replaced.
        let size = self.fontSize ?? self.storyboardFontSize ?? 14
        self.titleLabel?.font = UIFont.boldSystemFont(ofSize: size)
        self.titleLabel?.adjustsFontSizeToFitWidth = false
        
        switch self.style
        {
        case .custom: break // Don't update insets in case client has updated them.
        case .pill:
            self.contentEdgeInsets = UIEdgeInsets(
                top: Self.contentInsets.top,
                left: Self.contentInsets.leading,
                bottom: Self.contentInsets.bottom,
                right: Self.contentInsets.trailing
            )
            self.layer.cornerRadius = self.bounds.height / 2
        }
    }
    

    @objc func updateCountdown()
    {
        guard let endDate = self.countdownDate else { return }
        
        let startDate = Date()
        
        let interval = endDate.timeIntervalSince(startDate)
        guard interval > 0 else {
            self.isEnabled = true
            return
        }
        
        let text: String?
        
        if interval < (1 * 60 * 60)
        {
            self.dateComponentsFormatter.unitsStyle = .positional
            self.dateComponentsFormatter.allowedUnits = [.minute, .second]
            
            text = self.dateComponentsFormatter.string(from: startDate, to: endDate)
        }
        else if interval < (2 * 24 * 60 * 60)
        {
            self.dateComponentsFormatter.unitsStyle = .positional
            self.dateComponentsFormatter.allowedUnits = [.hour, .minute, .second]
            
            text = self.dateComponentsFormatter.string(from: startDate, to: endDate)
        }
        else
        {
            self.dateComponentsFormatter.unitsStyle = .full
            self.dateComponentsFormatter.allowedUnits = [.day]
            
            let numberOfDays = endDate.numberOfCalendarDays(since: startDate)
            text = String(format: NSLocalizedString("%@ DAYS", comment: ""), NSNumber(value: numberOfDays))
        }
        
        if let text = text
        {            
            UIView.performWithoutAnimation {
                self.isEnabled = false
                self.setTitle(text, for: .disabled)
                self.layoutIfNeeded()
            }
        }
        else
        {
            self.isEnabled = true
        }
    }
}
