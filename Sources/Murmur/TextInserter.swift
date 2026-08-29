import AppKit

/// Puts text into whichever app currently has keyboard focus.
///
/// The standard trick (used by every dictation tool): put the text on the
/// pasteboard, synthesise ⌘V, then quietly restore whatever the user had
/// copied before. Direct Accessibility-API insertion is less reliable across
/// apps, so pasteboard + ⌘V it is.
@MainActor
final class TextInserter {
    private static let pasteKeyCode: CGKeyCode = 9  // kVK_ANSI_V

    func insert(_ text: String) {
        let pasteboard = NSPasteboard.general
        let saved = snapshot(pasteboard)

        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)
        let ourChangeCount = pasteboard.changeCount

        postCommandV()

        // Give the frontmost app a moment to service the paste, then put the
        // user's original clipboard back — unless they copied something new.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) {
            guard pasteboard.changeCount == ourChangeCount else { return }
            Self.restore(saved, to: pasteboard)
        }
    }

    private func postCommandV() {
        let source = CGEventSource(stateID: .combinedSessionState)
        let keyDown = CGEvent(
            keyboardEventSource: source, virtualKey: Self.pasteKeyCode, keyDown: true)
        let keyUp = CGEvent(
            keyboardEventSource: source, virtualKey: Self.pasteKeyCode, keyDown: false)
        keyDown?.flags = .maskCommand
        keyUp?.flags = .maskCommand
        keyDown?.post(tap: .cghidEventTap)
        keyUp?.post(tap: .cghidEventTap)
    }

    // MARK: - Clipboard preservation

    private func snapshot(_ pasteboard: NSPasteboard) -> [[NSPasteboard.PasteboardType: Data]] {
        (pasteboard.pasteboardItems ?? []).map { item in
            var contents = [NSPasteboard.PasteboardType: Data]()
            for type in item.types {
                if let data = item.data(forType: type) {
                    contents[type] = data
                }
            }
            return contents
        }
    }

    private static func restore(
        _ saved: [[NSPasteboard.PasteboardType: Data]], to pasteboard: NSPasteboard
    ) {
        guard !saved.isEmpty else { return }
        pasteboard.clearContents()
        let items = saved.map { contents -> NSPasteboardItem in
            let item = NSPasteboardItem()
            for (type, data) in contents {
                item.setData(data, forType: type)
            }
            return item
        }
        pasteboard.writeObjects(items)
    }
}
