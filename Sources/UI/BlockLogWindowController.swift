import Cocoa

// MARK: - Small views

/// A rounded, softly filled box (stat cards, icon tiles, pills). The fill is a closure so it follows light and
/// dark mode instead of being frozen when the view was made.
final class CardView: NSView {
    private let fill: () -> NSColor
    private let radius: CGFloat

    init(radius: CGFloat = 10, fill: @escaping () -> NSColor = { NSColor.labelColor.withAlphaComponent(0.06) }) {
        self.fill = fill
        self.radius = radius
        super.init(frame: .zero)
        wantsLayer = true
        translatesAutoresizingMaskIntoConstraints = false
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    override var wantsUpdateLayer: Bool { true }

    override func updateLayer() {
        effectiveAppearance.performAsCurrentDrawingAppearance {
            layer?.backgroundColor = fill().cgColor
            layer?.cornerRadius = radius
        }
    }
}

/// A big number with a caption underneath.
final class StatCard: NSView {
    private let number = NSTextField(labelWithString: "0")
    private let caption = NSTextField(labelWithString: "")
    private let detail = NSTextField(labelWithString: "")

    init(caption text: String) {
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false

        let card = CardView()
        addSubview(card)

        number.font = .systemFont(ofSize: 24, weight: .semibold)
        caption.stringValue = text
        caption.font = .systemFont(ofSize: 11, weight: .medium)
        caption.textColor = .secondaryLabelColor
        detail.font = .systemFont(ofSize: 11)
        detail.textColor = .tertiaryLabelColor
        detail.lineBreakMode = .byTruncatingTail

        let column = NSStackView(views: [number, caption, detail])
        column.orientation = .vertical
        column.alignment = .leading
        column.spacing = 1
        column.translatesAutoresizingMaskIntoConstraints = false
        card.addSubview(column)

        NSLayoutConstraint.activate([
            card.leadingAnchor.constraint(equalTo: leadingAnchor),
            card.trailingAnchor.constraint(equalTo: trailingAnchor),
            card.topAnchor.constraint(equalTo: topAnchor),
            card.bottomAnchor.constraint(equalTo: bottomAnchor),
            column.leadingAnchor.constraint(equalTo: card.leadingAnchor, constant: 14),
            column.trailingAnchor.constraint(lessThanOrEqualTo: card.trailingAnchor, constant: -10),
            column.centerYAnchor.constraint(equalTo: card.centerYAnchor)
        ])
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    func set(_ value: Int, detail text: String) {
        number.stringValue = "\(value)"
        detail.stringValue = text
    }
}

/// What the image model scored for each part of the screen, drawn the way the scanner cut the screen up: the whole
/// screen, a 2x2 grid and a 3x3 grid. The part that decided the block has a red outline.
final class ScoreMapView: NSView {
    var scores: [Double] = [] { didSet { needsDisplay = true } }

    override var isFlipped: Bool { true }
    override var intrinsicContentSize: NSSize { NSSize(width: NSView.noIntrinsicMetric, height: 158) }

    override func draw(_ dirtyRect: NSRect) {
        guard scores.count == 14 else { return }
        let top = scores.max() ?? 0
        let topIndex = scores.firstIndex(of: top) ?? 0

        let heading = NSAttributedString(string: "WHAT THE MODEL SCORED, BY PART OF THE SCREEN", attributes: [
            .font: NSFont.systemFont(ofSize: 10.5, weight: .semibold), .foregroundColor: NSColor.secondaryLabelColor, .kern: 0.8
        ])
        heading.draw(at: NSPoint(x: 0, y: 0))

        let gap: CGFloat = 16
        let gridWidth = min(190, (bounds.width - 2 * gap) / 3)
        let gridHeight = gridWidth / 1.6
        let originY: CGFloat = 24

        let layouts: [(title: String, columns: Int, rows: Int, first: Int)] = [
            ("Whole screen", 1, 1, 0), ("Quarters", 2, 2, 1), ("Ninths", 3, 3, 5)
        ]
        for (position, layout) in layouts.enumerated() {
            let originX = CGFloat(position) * (gridWidth + gap)
            let tileWidth = gridWidth / CGFloat(layout.columns)
            let tileHeight = gridHeight / CGFloat(layout.rows)
            for row in 0..<layout.rows {
                for column in 0..<layout.columns {
                    let index = layout.first + row * layout.columns + column
                    let score = scores[index]
                    let frame = NSRect(x: originX + CGFloat(column) * tileWidth, y: originY + CGFloat(row) * tileHeight,
                                       width: tileWidth, height: tileHeight)
                    let alpha = 0.05 + 0.85 * CGFloat(score)
                    NSColor.systemRed.withAlphaComponent(alpha).setFill()
                    frame.fill(using: .sourceOver)
                    NSColor.separatorColor.setStroke()
                    let outline = NSBezierPath(rect: frame.insetBy(dx: 0.25, dy: 0.25))
                    outline.lineWidth = 0.5
                    outline.stroke()

                    let text = ImageScanLogic.percent(score)
                    let small = layout.columns == 3
                    let attributes: [NSAttributedString.Key: Any] = [
                        .font: NSFont.monospacedDigitSystemFont(ofSize: small ? 9.5 : 11, weight: score >= 0.5 ? .semibold : .regular),
                        .foregroundColor: score >= 0.55 ? NSColor.white : NSColor.labelColor
                    ]
                    let size = (text as NSString).size(withAttributes: attributes)
                    (text as NSString).draw(at: NSPoint(x: frame.midX - size.width / 2, y: frame.midY - size.height / 2), withAttributes: attributes)
                }
            }
            // Outline the tile that decided it.
            if topIndex >= layout.first, topIndex < layout.first + layout.columns * layout.rows {
                let local = topIndex - layout.first
                let frame = NSRect(x: originX + CGFloat(local % layout.columns) * tileWidth,
                                   y: originY + CGFloat(local / layout.columns) * tileHeight, width: tileWidth, height: tileHeight)
                NSColor.systemRed.setStroke()
                let marker = NSBezierPath(rect: frame.insetBy(dx: 1, dy: 1))
                marker.lineWidth = 2
                marker.stroke()
            }
            let caption = NSAttributedString(string: layout.title, attributes: [
                .font: NSFont.systemFont(ofSize: 11), .foregroundColor: NSColor.secondaryLabelColor
            ])
            caption.draw(at: NSPoint(x: originX, y: originY + gridHeight + 5))
        }
    }
}

/// One entry in the list: icon, what happened, where, and when.
final class EventRowCell: NSTableCellView {
    static let identifier = NSUserInterfaceItemIdentifier("BlockEventRow")

    private let iconTile = CardView(radius: 8)
    private let iconView = NSImageView()
    private let titleField = NSTextField(labelWithString: "")
    private let subtitleField = NSTextField(labelWithString: "")
    private let timeField = NSTextField(labelWithString: "")
    private var accent: NSColor = .systemRed

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        identifier = EventRowCell.identifier

        iconView.translatesAutoresizingMaskIntoConstraints = false
        iconView.imageScaling = .scaleProportionallyDown
        iconTile.addSubview(iconView)

        titleField.font = .systemFont(ofSize: 13, weight: .semibold)
        titleField.lineBreakMode = .byTruncatingTail
        subtitleField.font = .systemFont(ofSize: 11)
        subtitleField.textColor = .secondaryLabelColor
        subtitleField.lineBreakMode = .byTruncatingMiddle
        timeField.font = .monospacedDigitSystemFont(ofSize: 11, weight: .regular)
        timeField.textColor = .secondaryLabelColor
        timeField.alignment = .right
        for field in [titleField, subtitleField, timeField] {
            field.translatesAutoresizingMaskIntoConstraints = false
            addSubview(field)
        }
        addSubview(iconTile)

        NSLayoutConstraint.activate([
            iconTile.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 12),
            iconTile.centerYAnchor.constraint(equalTo: centerYAnchor),
            iconTile.widthAnchor.constraint(equalToConstant: 34),
            iconTile.heightAnchor.constraint(equalToConstant: 34),
            iconView.centerXAnchor.constraint(equalTo: iconTile.centerXAnchor),
            iconView.centerYAnchor.constraint(equalTo: iconTile.centerYAnchor),
            iconView.widthAnchor.constraint(equalToConstant: 18),
            iconView.heightAnchor.constraint(equalToConstant: 18),

            timeField.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -12),
            timeField.topAnchor.constraint(equalTo: topAnchor, constant: 11),
            timeField.widthAnchor.constraint(equalToConstant: 42),

            titleField.leadingAnchor.constraint(equalTo: iconTile.trailingAnchor, constant: 10),
            titleField.trailingAnchor.constraint(equalTo: timeField.leadingAnchor, constant: -6),
            titleField.topAnchor.constraint(equalTo: topAnchor, constant: 10),

            subtitleField.leadingAnchor.constraint(equalTo: titleField.leadingAnchor),
            subtitleField.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -12),
            subtitleField.topAnchor.constraint(equalTo: titleField.bottomAnchor, constant: 2)
        ])
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    func configure(with event: BlockEvent) {
        accent = BlockLogWindowController.accent(for: event)
        titleField.stringValue = event.headline
        subtitleField.stringValue = (event.page ?? "address not readable") + "  ·  " + BlockEvent.appName(event.app)
        timeField.stringValue = BlockEvent.timeText(event.date)

        iconView.image = BlockLogWindowController.symbol(for: event.check)
        iconView.contentTintColor = accent
        iconTile.setNeedsDisplay(iconTile.bounds)
        iconTile.layer?.backgroundColor = accent.withAlphaComponent(0.15).cgColor
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        effectiveAppearance.performAsCurrentDrawingAppearance {
            iconTile.layer?.backgroundColor = accent.withAlphaComponent(0.15).cgColor
        }
    }
}

// MARK: - The window

/// The Block Log: everything Word Blocker closed, or nearly closed, and exactly why. A list grouped by day on the
/// left (filter by kind, search by anything), the full explanation on the right: which check fired, the rule or
/// score behind it, and for images a map of what the model scored on each part of the screen.
public final class BlockLogWindowController: NSWindowController, NSTableViewDataSource, NSTableViewDelegate, NSSearchFieldDelegate {
    public static let shared = BlockLogWindowController()

    private enum Row {
        case header(String)
        case event(BlockEvent)

        var eventID: String? {
            if case .event(let event) = self { return event.id }
            return nil
        }
    }

    /// Where events come from; the shared window reads the log file, a preview can supply its own.
    private let loader: () -> [BlockEvent]
    private var allEvents: [BlockEvent] = []
    private var rows: [Row] = []
    private var filter: BlockEvent.Filter = .blocks
    private var query = ""
    private var selectedID: String?
    private var observer: NSObjectProtocol?

    // Views
    private let segmented = NSSegmentedControl()
    private let searchField = NSSearchField()
    private let todayCard = StatCard(caption: "Blocked today")
    private let weekCard = StatCard(caption: "Last 7 days")
    private let totalCard = StatCard(caption: "All logged")
    private let splitView = NSSplitView()
    private let tableView = NSTableView()
    private let emptyLabel = NSTextField(wrappingLabelWithString: "")
    private let detailContainer = NSView()
    private let detailStack = NSStackView()
    private let detailIconTile = CardView(radius: 12)
    private let detailIcon = NSImageView()
    private let detailTitle = NSTextField(labelWithString: "")
    private let detailSubtitle = NSTextField(labelWithString: "")
    private let badgeRow = NSStackView()
    private let mapView = ScoreMapView()
    private let reportScroll = NSTextView.scrollableTextView()
    private let placeholder = NSTextField(wrappingLabelWithString: "Select an entry to see why it was blocked.")
    private let footerLabel = NSTextField(labelWithString: "")
    private let copyButton = NSButton(title: "Copy Details", target: nil, action: nil)
    private let revealButton = NSButton(title: "Show Log File", target: nil, action: nil)
    private var detailAccent: NSColor = .systemRed

    private var reportView: NSTextView { reportScroll.documentView as! NSTextView }

    private convenience init() {
        self.init(loader: { BlockLog.loadEvents() })
    }

    /// `loader` supplies the events (newest first); tests and previews pass their own.
    public init(loader: @escaping () -> [BlockEvent]) {
        self.loader = loader
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1020, height: 740),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered, defer: false
        )
        window.title = "Block Log"
        window.minSize = NSSize(width: 820, height: 520)
        window.isReleasedWhenClosed = false
        window.center()
        window.setFrameAutosaveName("WordBlockerBlockLog")
        super.init(window: window)
        buildUI()
        observer = NotificationCenter.default.addObserver(forName: .blockLogChanged, object: nil, queue: .main) { [weak self] _ in
            self?.reload()
        }
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    deinit {
        if let observer = observer { NotificationCenter.default.removeObserver(observer) }
    }

    /// Brings the window forward with the latest entries.
    public func show() {
        reload()
        NSApp.activate(ignoringOtherApps: true)
        showWindow(nil)
        window?.makeKeyAndOrderFront(nil)
        window?.contentView?.layoutSubtreeIfNeeded()
        if splitView.subviews.count == 2, splitView.subviews[0].frame.width < 250 || splitView.subviews[0].frame.width > 520 {
            splitView.setPosition(360, ofDividerAt: 0)
        }
    }

    // MARK: Look

    static func accent(for event: BlockEvent) -> NSColor {
        event.outcome == .nearMiss ? .systemOrange : .systemRed
    }

    static func symbol(for check: String) -> NSImage? {
        let name: String
        switch check {
        case "adult-site": name = "globe"
        case "adult-search": name = "magnifyingglass"
        case "adult-community": name = "person.2.fill"
        case "adult-title": name = "textformat"
        case "page-text": name = "doc.text.fill"
        case "image-scan": name = "photo.fill"
        case "image-recheck": name = "eye.fill"
        case "image-near-miss": name = "exclamationmark.triangle.fill"
        case "image-held-back": name = "hand.raised.fill"
        default: name = "shield.fill"
        }
        return NSImage(systemSymbolName: name, accessibilityDescription: nil)
    }

    // MARK: Building

    private func buildUI() {
        guard let content = window?.contentView else { return }

        segmented.segmentCount = 4
        segmented.segmentStyle = .rounded
        segmented.trackingMode = .selectOne
        segmented.target = self
        segmented.action = #selector(filterChanged)
        segmented.translatesAutoresizingMaskIntoConstraints = false

        searchField.placeholderString = "Search reasons, pages, apps"
        searchField.delegate = self
        searchField.sendsSearchStringImmediately = true
        searchField.translatesAutoresizingMaskIntoConstraints = false

        let cards = NSStackView(views: [todayCard, weekCard, totalCard])
        cards.orientation = .horizontal
        cards.distribution = .fillEqually
        cards.spacing = 10
        cards.translatesAutoresizingMaskIntoConstraints = false

        // List
        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("event"))
        column.resizingMask = .autoresizingMask
        tableView.addTableColumn(column)
        tableView.headerView = nil
        tableView.rowSizeStyle = .custom
        tableView.intercellSpacing = NSSize(width: 0, height: 0)
        tableView.selectionHighlightStyle = .regular
        tableView.floatsGroupRows = false
        tableView.dataSource = self
        tableView.delegate = self
        tableView.allowsEmptySelection = true
        tableView.style = .sourceList

        let listScroll = NSScrollView()
        listScroll.documentView = tableView
        listScroll.hasVerticalScroller = true
        listScroll.drawsBackground = false
        listScroll.translatesAutoresizingMaskIntoConstraints = false

        emptyLabel.alignment = .center
        emptyLabel.font = .systemFont(ofSize: 13)
        emptyLabel.textColor = .secondaryLabelColor
        emptyLabel.translatesAutoresizingMaskIntoConstraints = false

        let listPane = NSView()
        listPane.addSubview(listScroll)
        listPane.addSubview(emptyLabel)
        NSLayoutConstraint.activate([
            listScroll.leadingAnchor.constraint(equalTo: listPane.leadingAnchor),
            listScroll.trailingAnchor.constraint(equalTo: listPane.trailingAnchor),
            listScroll.topAnchor.constraint(equalTo: listPane.topAnchor),
            listScroll.bottomAnchor.constraint(equalTo: listPane.bottomAnchor),
            emptyLabel.centerXAnchor.constraint(equalTo: listPane.centerXAnchor),
            emptyLabel.centerYAnchor.constraint(equalTo: listPane.centerYAnchor, constant: -20),
            emptyLabel.widthAnchor.constraint(lessThanOrEqualTo: listPane.widthAnchor, constant: -48),
            listPane.widthAnchor.constraint(greaterThanOrEqualToConstant: 280)
        ])

        buildDetail()

        splitView.isVertical = true
        splitView.dividerStyle = .thin
        splitView.translatesAutoresizingMaskIntoConstraints = false
        splitView.addArrangedSubview(listPane)
        splitView.addArrangedSubview(detailContainer)
        splitView.setHoldingPriority(NSLayoutConstraint.Priority(260), forSubviewAt: 0)

        // Footer
        let separator = NSBox()
        separator.boxType = .separator
        separator.translatesAutoresizingMaskIntoConstraints = false

        footerLabel.font = .systemFont(ofSize: 11)
        footerLabel.textColor = .secondaryLabelColor
        footerLabel.lineBreakMode = .byTruncatingTail
        footerLabel.translatesAutoresizingMaskIntoConstraints = false

        copyButton.target = self
        copyButton.action = #selector(copyDetails)
        copyButton.bezelStyle = .rounded
        copyButton.controlSize = .small
        revealButton.target = self
        revealButton.action = #selector(revealLogFile)
        revealButton.bezelStyle = .rounded
        revealButton.controlSize = .small
        let buttons = NSStackView(views: [copyButton, revealButton])
        buttons.orientation = .horizontal
        buttons.spacing = 8
        buttons.translatesAutoresizingMaskIntoConstraints = false

        for view in [segmented, searchField, cards, splitView, separator, footerLabel, buttons] as [NSView] {
            content.addSubview(view)
        }

        NSLayoutConstraint.activate([
            segmented.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 16),
            segmented.topAnchor.constraint(equalTo: content.topAnchor, constant: 14),
            searchField.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -16),
            searchField.centerYAnchor.constraint(equalTo: segmented.centerYAnchor),
            searchField.widthAnchor.constraint(equalToConstant: 250),
            segmented.trailingAnchor.constraint(lessThanOrEqualTo: searchField.leadingAnchor, constant: -12),

            cards.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 16),
            cards.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -16),
            cards.topAnchor.constraint(equalTo: segmented.bottomAnchor, constant: 12),
            cards.heightAnchor.constraint(equalToConstant: 62),

            splitView.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            splitView.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            splitView.topAnchor.constraint(equalTo: cards.bottomAnchor, constant: 14),
            splitView.bottomAnchor.constraint(equalTo: separator.topAnchor),

            separator.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            separator.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            separator.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -40),
            separator.heightAnchor.constraint(equalToConstant: 1),

            footerLabel.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 16),
            footerLabel.centerYAnchor.constraint(equalTo: content.bottomAnchor, constant: -20),
            footerLabel.trailingAnchor.constraint(lessThanOrEqualTo: buttons.leadingAnchor, constant: -12),
            buttons.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -16),
            buttons.centerYAnchor.constraint(equalTo: footerLabel.centerYAnchor)
        ])
    }

    private func buildDetail() {
        detailContainer.translatesAutoresizingMaskIntoConstraints = false

        detailIcon.imageScaling = .scaleProportionallyDown
        detailIcon.translatesAutoresizingMaskIntoConstraints = false
        detailIconTile.addSubview(detailIcon)
        NSLayoutConstraint.activate([
            detailIconTile.widthAnchor.constraint(equalToConstant: 48),
            detailIconTile.heightAnchor.constraint(equalToConstant: 48),
            detailIcon.centerXAnchor.constraint(equalTo: detailIconTile.centerXAnchor),
            detailIcon.centerYAnchor.constraint(equalTo: detailIconTile.centerYAnchor),
            detailIcon.widthAnchor.constraint(equalToConstant: 26),
            detailIcon.heightAnchor.constraint(equalToConstant: 26)
        ])

        detailTitle.font = .systemFont(ofSize: 21, weight: .semibold)
        detailTitle.lineBreakMode = .byTruncatingTail
        detailSubtitle.font = .systemFont(ofSize: 12)
        detailSubtitle.textColor = .secondaryLabelColor
        let titles = NSStackView(views: [detailTitle, detailSubtitle])
        titles.orientation = .vertical
        titles.alignment = .leading
        titles.spacing = 3

        let header = NSStackView(views: [detailIconTile, titles])
        header.orientation = .horizontal
        header.alignment = .centerY
        header.spacing = 14

        badgeRow.orientation = .horizontal
        badgeRow.spacing = 8
        badgeRow.alignment = .centerY

        reportScroll.drawsBackground = false
        reportScroll.hasVerticalScroller = true
        reportScroll.borderType = .noBorder
        let text = reportView
        text.isEditable = false
        text.isSelectable = true
        text.drawsBackground = false
        text.textContainerInset = NSSize(width: 0, height: 2)
        text.textContainer?.lineFragmentPadding = 0
        reportScroll.setContentHuggingPriority(.defaultLow, for: .vertical)
        reportScroll.setContentCompressionResistancePriority(.defaultLow, for: .vertical)

        detailStack.orientation = .vertical
        detailStack.alignment = .leading
        detailStack.spacing = 14
        detailStack.edgeInsets = NSEdgeInsets(top: 22, left: 26, bottom: 14, right: 26)
        detailStack.translatesAutoresizingMaskIntoConstraints = false
        for view in [header, badgeRow, mapView, reportScroll] as [NSView] {
            view.translatesAutoresizingMaskIntoConstraints = false
            detailStack.addArrangedSubview(view)
        }
        detailContainer.addSubview(detailStack)

        placeholder.alignment = .center
        placeholder.font = .systemFont(ofSize: 13)
        placeholder.textColor = .tertiaryLabelColor
        placeholder.translatesAutoresizingMaskIntoConstraints = false
        detailContainer.addSubview(placeholder)

        NSLayoutConstraint.activate([
            detailStack.leadingAnchor.constraint(equalTo: detailContainer.leadingAnchor),
            detailStack.trailingAnchor.constraint(equalTo: detailContainer.trailingAnchor),
            detailStack.topAnchor.constraint(equalTo: detailContainer.topAnchor),
            detailStack.bottomAnchor.constraint(equalTo: detailContainer.bottomAnchor),
            mapView.widthAnchor.constraint(equalTo: detailStack.widthAnchor, constant: -52),
            reportScroll.widthAnchor.constraint(equalTo: detailStack.widthAnchor, constant: -52),
            detailContainer.widthAnchor.constraint(greaterThanOrEqualToConstant: 400),
            placeholder.centerXAnchor.constraint(equalTo: detailContainer.centerXAnchor),
            placeholder.centerYAnchor.constraint(equalTo: detailContainer.centerYAnchor),
            placeholder.widthAnchor.constraint(lessThanOrEqualTo: detailContainer.widthAnchor, constant: -60)
        ])
    }

    // MARK: Data

    /// Reads the log again and redraws, keeping the selected entry when it is still there.
    public func reload() {
        allEvents = loader()
        refresh()
    }

    private func refresh() {
        // Segment labels carry their counts.
        let counts = [
            allEvents.filter { $0.matches(.blocks) }.count, allEvents.filter { $0.matches(.images) }.count,
            allEvents.filter { $0.matches(.websites) }.count, allEvents.filter { $0.matches(.nearMisses) }.count
        ]
        for (index, title) in ["All blocks", "Images", "Websites", "Near misses"].enumerated() {
            segmented.setLabel("\(title)  \(counts[index])", forSegment: index)
        }
        segmented.selectedSegment = filter.rawValue

        let stats = BlockEvent.counts(allEvents)
        let today = BlockEvent.breakdown(allEvents, since: Calendar.current.startOfDay(for: Date()))
        let week = BlockEvent.breakdown(allEvents, since: Calendar.current.date(byAdding: .day, value: -7, to: Date()) ?? .distantPast)
        todayCard.set(stats.today, detail: stats.today == 0 ? "nothing closed" : "\(today.images) images · \(today.websites) sites")
        weekCard.set(stats.week, detail: stats.week == 0 ? "nothing closed" : "\(week.images) images · \(week.websites) sites")
        totalCard.set(stats.total, detail: counts[3] == 0 ? "no near misses" : "\(counts[3]) near misses")

        let shown = allEvents.filter { $0.matches(filter) && $0.matches(search: query) }
        rows = []
        var lastDay = ""
        for event in shown {
            let day = BlockEvent.dayTitle(for: event.date)
            if day != lastDay {
                rows.append(.header(day))
                lastDay = day
            }
            rows.append(.event(event))
        }
        tableView.reloadData()

        // Keep the selection if the entry is still shown; otherwise the newest one.
        var rowToSelect: Int?
        for (index, row) in rows.enumerated() {
            if case .event(let event) = row {
                if event.id == selectedID { rowToSelect = index; break }
                if rowToSelect == nil { rowToSelect = index }
            }
        }
        if let row = rowToSelect {
            tableView.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
            // Only move the list when the selection moved (a live update must not yank it), and when the
            // entry is first under its day heading, show the heading too.
            if selectedID != rows[row].eventID {
                if row <= 1 { tableView.scrollToBeginningOfDocument(nil) } else { tableView.scrollRowToVisible(row) }
            }
        } else {
            tableView.deselectAll(nil)
        }
        showSelection()

        if shown.isEmpty {
            if allEvents.isEmpty {
                emptyLabel.stringValue = "Nothing has been blocked yet.\n\nWhen Word Blocker closes a site or an image, it is recorded here with the reason."
            } else if filter == .nearMisses && query.isEmpty {
                emptyLabel.stringValue = "No near misses.\n\nA near miss is a high image score that was not enough to close anything."
            } else {
                emptyLabel.stringValue = "No entries match.\n\nTry another filter or search."
            }
        }
        emptyLabel.isHidden = !shown.isEmpty
        footerLabel.stringValue = "\(shown.count) shown of \(allEvents.count) logged  ·  kept on this Mac only: no search words, page text or pictures are stored"
    }

    private func selectedEvent() -> BlockEvent? {
        let row = tableView.selectedRow
        guard row >= 0, row < rows.count, case .event(let event) = rows[row] else { return nil }
        return event
    }

    // MARK: Detail

    private func showSelection() {
        guard let event = selectedEvent() else {
            selectedID = nil
            detailStack.isHidden = true
            placeholder.isHidden = false
            placeholder.stringValue = allEvents.isEmpty ? "Blocked sites and images will be explained here:\nwhich check fired, the rule or score behind it, and where on the screen." : "Select an entry to see why it was blocked."
            copyButton.isEnabled = false
            return
        }
        selectedID = event.id
        detailStack.isHidden = false
        placeholder.isHidden = true
        copyButton.isEnabled = true

        detailAccent = BlockLogWindowController.accent(for: event)
        detailIcon.image = BlockLogWindowController.symbol(for: event.check)
        detailIcon.contentTintColor = detailAccent
        detailIconTile.layer?.backgroundColor = detailAccent.withAlphaComponent(0.15).cgColor
        detailTitle.stringValue = event.headline

        let formatter = DateFormatter()
        formatter.dateFormat = "EEEE d MMMM yyyy, HH:mm:ss"
        detailSubtitle.stringValue = formatter.string(from: event.date)

        badgeRow.arrangedSubviews.forEach { badgeRow.removeArrangedSubview($0); $0.removeFromSuperview() }
        badgeRow.addArrangedSubview(pill(event.outcome == .blocked ? "Blocked" : "Near miss", color: detailAccent))
        badgeRow.addArrangedSubview(pill(event.action, color: .systemGray))
        badgeRow.addArrangedSubview(pill(BlockEvent.appName(event.app), color: .systemBlue))
        badgeRow.addArrangedSubview(pill(event.kind == .image ? "Image scanner" : "Website check", color: .systemGray))

        if event.kind == .image, let scores = event.scores, scores.count == 14 {
            mapView.scores = scores
            mapView.isHidden = false
        } else {
            mapView.isHidden = true
        }

        reportView.textStorage?.setAttributedString(report(for: event))
        reportView.scrollToBeginningOfDocument(nil)
    }

    private func pill(_ text: String, color: NSColor) -> NSView {
        let box = CardView(radius: 9, fill: { color.withAlphaComponent(0.16) })
        let label = NSTextField(labelWithString: text)
        label.font = .systemFont(ofSize: 11, weight: .medium)
        label.textColor = color == .systemGray ? .secondaryLabelColor : color
        label.translatesAutoresizingMaskIntoConstraints = false
        box.addSubview(label)
        NSLayoutConstraint.activate([
            label.leadingAnchor.constraint(equalTo: box.leadingAnchor, constant: 9),
            label.trailingAnchor.constraint(equalTo: box.trailingAnchor, constant: -9),
            label.topAnchor.constraint(equalTo: box.topAnchor, constant: 3),
            label.bottomAnchor.constraint(equalTo: box.bottomAnchor, constant: -3)
        ])
        return box
    }

    /// The written explanation: why, the evidence, the page, and a note on what the log keeps.
    private func report(for event: BlockEvent) -> NSAttributedString {
        let result = NSMutableAttributedString()

        func heading(_ text: String) {
            let style = NSMutableParagraphStyle()
            style.paragraphSpacingBefore = result.length == 0 ? 0 : 18
            style.paragraphSpacing = 6
            result.append(NSAttributedString(string: text.uppercased() + "\n", attributes: [
                .font: NSFont.systemFont(ofSize: 10.5, weight: .semibold), .foregroundColor: NSColor.secondaryLabelColor,
                .kern: 0.8, .paragraphStyle: style
            ]))
        }

        heading(event.outcome == .blocked ? "Why it was blocked" : "Why it was flagged, and why nothing closed")
        let body = NSMutableParagraphStyle()
        body.lineSpacing = 4
        result.append(NSAttributedString(string: event.why + "\n", attributes: [
            .font: NSFont.systemFont(ofSize: 14), .foregroundColor: NSColor.labelColor, .paragraphStyle: body
        ]))

        heading("Evidence")
        let evidence = NSMutableParagraphStyle()
        evidence.tabStops = [NSTextTab(textAlignment: .left, location: 150)]
        evidence.defaultTabInterval = 150
        evidence.headIndent = 150
        evidence.paragraphSpacing = 5
        for detail in event.details {
            result.append(NSAttributedString(string: detail.label + "\t", attributes: [
                .font: NSFont.systemFont(ofSize: 12), .foregroundColor: NSColor.secondaryLabelColor, .paragraphStyle: evidence
            ]))
            result.append(NSAttributedString(string: detail.value + "\n", attributes: [
                .font: NSFont.systemFont(ofSize: 13), .foregroundColor: NSColor.labelColor, .paragraphStyle: evidence
            ]))
        }

        heading("Page")
        result.append(NSAttributedString(string: (event.page ?? "The browser did not show the address.") + "\n", attributes: [
            .font: event.page == nil ? NSFont.systemFont(ofSize: 13) : NSFont.monospacedSystemFont(ofSize: 12, weight: .regular),
            .foregroundColor: NSColor.labelColor
        ]))

        heading("About this entry")
        let note = event.kind == .image
            ? "The image model gives one number for each look: how likely that part of the screen is to be explicit. It does not name what it sees. The picture itself is never saved."
            : "Only the rule that matched is kept. Search words and page text are not saved, and the address is stored without its query string."
        result.append(NSAttributedString(string: note + "\n", attributes: [
            .font: NSFont.systemFont(ofSize: 12), .foregroundColor: NSColor.secondaryLabelColor, .paragraphStyle: body
        ]))
        return result
    }

    // MARK: Table

    public func numberOfRows(in tableView: NSTableView) -> Int { rows.count }

    public func tableView(_ tableView: NSTableView, isGroupRow row: Int) -> Bool {
        if case .header = rows[row] { return true }
        return false
    }

    public func tableView(_ tableView: NSTableView, shouldSelectRow row: Int) -> Bool {
        if case .event = rows[row] { return true }
        return false
    }

    public func tableView(_ tableView: NSTableView, heightOfRow row: Int) -> CGFloat {
        if case .header = rows[row] { return 30 }
        return 58
    }

    public func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        switch rows[row] {
        case .header(let title):
            let cell = NSTableCellView()
            let label = NSTextField(labelWithString: title.uppercased())
            label.font = .systemFont(ofSize: 10.5, weight: .semibold)
            label.textColor = .secondaryLabelColor
            label.translatesAutoresizingMaskIntoConstraints = false
            cell.addSubview(label)
            NSLayoutConstraint.activate([
                label.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 14),
                label.bottomAnchor.constraint(equalTo: cell.bottomAnchor, constant: -4)
            ])
            return cell
        case .event(let event):
            let cell = tableView.makeView(withIdentifier: EventRowCell.identifier, owner: self) as? EventRowCell ?? EventRowCell(frame: .zero)
            cell.configure(with: event)
            return cell
        }
    }

    public func tableViewSelectionDidChange(_ notification: Notification) {
        showSelection()
    }

    // MARK: Actions

    @objc private func filterChanged() {
        filter = BlockEvent.Filter(rawValue: segmented.selectedSegment) ?? .blocks
        refresh()
    }

    public func controlTextDidChange(_ notification: Notification) {
        query = searchField.stringValue
        refresh()
    }

    @objc private func copyDetails() {
        guard let event = selectedEvent() else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(event.copyText, forType: .string)
    }

    /// Cmd-C on the list copies the selected entry; with text selected on the right the text view handles it.
    @objc func copy(_ sender: Any?) {
        copyDetails()
    }

    @objc private func revealLogFile() {
        let url = BlockLog.fileURL
        if FileManager.default.fileExists(atPath: url.path) {
            NSWorkspace.shared.activateFileViewerSelecting([url])
        } else {
            NSWorkspace.shared.open(url.deletingLastPathComponent())
        }
    }
}
