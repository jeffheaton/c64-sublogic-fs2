import AppKit

/// Help ▸ Flight Simulator II Help (⌥⌘/): `HelpContent` in a scrolling, selectable text view, with
/// a button to the keyboard reference.
@MainActor
final class HelpWindowController: NSWindowController {
    private let showKeyboardReference: () -> Void

    init(showKeyboardReference: @escaping () -> Void) {
        self.showKeyboardReference = showKeyboardReference
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 620, height: 680),
                              styleMask: [.titled, .closable, .resizable, .miniaturizable],
                              backing: .buffered, defer: true)
        window.title = HelpContent.title
        window.isReleasedWhenClosed = false
        window.contentMinSize = NSSize(width: 420, height: 320)
        window.setFrameAutosaveName("FS2 Help")
        super.init(window: window)
        build()
        window.center()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("not used") }

    private func build() {
        let scroll = NSTextView.scrollableTextView()
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.drawsBackground = true
        if let text = scroll.documentView as? NSTextView {
            text.isEditable = false
            text.isSelectable = true
            text.drawsBackground = true
            text.backgroundColor = .textBackgroundColor
            text.textContainerInset = NSSize(width: 18, height: 16)
            text.textStorage?.setAttributedString(Self.attributedHelp())
        }

        let reference = NSButton(title: "Keyboard Reference…", target: self, action: #selector(openReference(_:)))
        reference.bezelStyle = .push
        let buttons = NSStackView(views: [NSView(), reference])
        buttons.orientation = .horizontal
        buttons.edgeInsets = NSEdgeInsets(top: 0, left: 16, bottom: 12, right: 16)

        let stack = NSStackView(views: [scroll, buttons])
        stack.orientation = .vertical
        stack.spacing = 10
        scroll.translatesAutoresizingMaskIntoConstraints = false
        buttons.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            scroll.widthAnchor.constraint(equalTo: stack.widthAnchor),
            buttons.widthAnchor.constraint(equalTo: stack.widthAnchor),
        ])
        window?.contentView = stack
    }

    @objc private func openReference(_ sender: Any?) { showKeyboardReference() }

    /// The help as styled text: a title, bold topic headings, paragraphs and hanging-indent bullets.
    static func attributedHelp() -> NSAttributedString {
        let out = NSMutableAttributedString()
        let body = NSFont.systemFont(ofSize: NSFont.systemFontSize)
        func paragraph(spacingBefore: CGFloat, indent: CGFloat = 0) -> NSParagraphStyle {
            let p = NSMutableParagraphStyle()
            p.paragraphSpacingBefore = spacingBefore
            p.paragraphSpacing = 4
            p.headIndent = indent
            p.lineSpacing = 1.5
            return p
        }
        func append(_ text: String, font: NSFont, color: NSColor = .labelColor, style: NSParagraphStyle) {
            out.append(NSAttributedString(string: text + "\n", attributes: [
                .font: font, .foregroundColor: color, .paragraphStyle: style,
            ]))
        }
        append(HelpContent.title, font: .boldSystemFont(ofSize: 20), style: paragraph(spacingBefore: 0))
        for topic in HelpContent.topics() {
            append(topic.title, font: .boldSystemFont(ofSize: 15), style: paragraph(spacingBefore: 12))
            for text in topic.paragraphs {
                if text.hasPrefix("• ") {
                    let bullet = NSMutableParagraphStyle()
                    bullet.setParagraphStyle(paragraph(spacingBefore: 0, indent: 16))
                    bullet.tabStops = [NSTextTab(textAlignment: .left, location: 16)]
                    append("•\t" + text.dropFirst(2), font: body, style: bullet)
                } else {
                    append(text, font: body, style: paragraph(spacingBefore: 2))
                }
            }
        }
        return out
    }
}
