import AppKit
import FS2Host

/// Machine ▸ Keyboard Reference (⌘/): the Mac ↔ C64 key table with what each key does in the game,
/// generated from the same mapping the keyboard uses (`KeyReference`).
@MainActor
final class KeyboardReferenceWindowController: NSWindowController, NSTableViewDataSource, NSTableViewDelegate {
    private enum Item {
        case header(String)
        case row(KeyReference.Row)
    }

    private var items: [Item] = []
    private let table = NSTableView()

    init() {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 860, height: 640),
                              styleMask: [.titled, .closable, .resizable, .miniaturizable],
                              backing: .buffered, defer: true)
        window.title = "Keyboard Reference"
        window.isReleasedWhenClosed = false
        window.setFrameAutosaveName("FS2 Keyboard Reference")
        super.init(window: window)
        reload()
        build()
        window.center()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("not used") }

    static let note = "Keys map by position to the C64 keyboard; the original program's own scan, repeat and "
        + "command dispatch run unchanged on top. Each press is one step, and holding a key repeats it the way "
        + "the C64 did (only the first two held keys repeat). For a Control combination hold Control, then "
        + "press the letter. ⌘ shortcuts always go to the Mac menus."

    func reload() {
        items = KeyReference.sections().flatMap { s in [Item.header(s.title)] + s.rows.map(Item.row) }
        table.reloadData()
    }

    private func build() {
        let columns: [(String, String, CGFloat)] = [
            ("mac", "Mac key", 190), ("c64", "Commodore 64", 200), ("function", "In Flight Simulator II", 440),
        ]
        for (id, title, width) in columns {
            let c = NSTableColumn(identifier: NSUserInterfaceItemIdentifier(id))
            c.title = title
            c.width = width
            c.minWidth = 80
            table.addTableColumn(c)
        }
        table.dataSource = self
        table.delegate = self
        table.usesAlternatingRowBackgroundColors = true
        table.columnAutoresizingStyle = .lastColumnOnlyAutoresizingStyle
        table.allowsColumnReordering = false
        table.style = .inset

        let scroll = NSScrollView()
        scroll.documentView = table
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true

        let note = NSTextField(wrappingLabelWithString: Self.note)
        note.textColor = .secondaryLabelColor
        note.font = .systemFont(ofSize: NSFont.smallSystemFontSize)

        let stack = NSStackView(views: [scroll, note])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 8
        stack.edgeInsets = NSEdgeInsets(top: 0, left: 0, bottom: 12, right: 0)
        scroll.translatesAutoresizingMaskIntoConstraints = false
        note.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            scroll.widthAnchor.constraint(equalTo: stack.widthAnchor),
            note.leadingAnchor.constraint(equalTo: stack.leadingAnchor, constant: 16),
            note.trailingAnchor.constraint(equalTo: stack.trailingAnchor, constant: -16),
        ])
        window?.contentView = stack
    }

    // MARK: Table

    func numberOfRows(in tableView: NSTableView) -> Int { items.count }

    func tableView(_ tableView: NSTableView, isGroupRow row: Int) -> Bool {
        if case .header = items[row] { return true }
        return false
    }

    func tableView(_ tableView: NSTableView, shouldSelectRow row: Int) -> Bool { false }

    /// Rows grow to fit the longest wrapped cell.
    func tableView(_ tableView: NSTableView, heightOfRow row: Int) -> CGFloat {
        guard case .row(let r) = items[row] else { return 26 }
        let font = NSFont.systemFont(ofSize: NSFont.systemFontSize)
        var height: CGFloat = 17
        for column in tableView.tableColumns {
            let text: String
            switch column.identifier.rawValue {
            case "mac": text = r.mac
            case "c64": text = r.c64
            default: text = r.function
            }
            let bounds = (text as NSString).boundingRect(
                with: NSSize(width: max(20, column.width - 8), height: .greatestFiniteMagnitude),
                options: [.usesLineFragmentOrigin, .usesFontLeading], attributes: [.font: font])
            height = max(height, ceil(bounds.height))
        }
        return height + 6
    }

    func tableViewColumnDidResize(_ notification: Notification) {
        table.noteHeightOfRows(withIndexesChanged: IndexSet(integersIn: 0..<items.count))
    }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        let text: String
        var bold = false
        switch items[row] {
        case .header(let title):
            text = title
            bold = true
        case .row(let r):
            switch tableColumn?.identifier.rawValue {
            case "mac": text = r.mac
            case "c64": text = r.c64
            default: text = r.function
            }
        }
        let id = NSUserInterfaceItemIdentifier(bold ? "header" : "cell")
        let field = (tableView.makeView(withIdentifier: id, owner: self) as? NSTextField)
            ?? NSTextField(wrappingLabelWithString: "")
        field.identifier = id
        field.stringValue = text
        field.font = bold ? .boldSystemFont(ofSize: NSFont.systemFontSize) : .systemFont(ofSize: NSFont.systemFontSize)
        field.lineBreakMode = .byWordWrapping
        field.isSelectable = false
        return field
    }
}
