import AppKit
import UniformTypeIdentifiers

// Pictures in meeting notes. A picture is a file in the meeting's own folder
// (Meetings/<meeting-id>/<uuid>.png|jpg) and appears in the notes text as a
// Markdown image line — `![](<uuid>.png)` — so `Meeting.notes` stays a plain
// String and the JSON schema doesn't change. The editor swaps those lines for
// inline images on load and back to Markdown on every edit.

/// An inline picture that remembers which file it came from.
final class MeetingImageAttachment: NSTextAttachment {
    var fileName = ""
}

enum MeetingImages {
    /// Widest an inline picture is drawn in the editor, in points.
    static let maxDisplayWidth: CGFloat = 480

    static func dir(_ meetingID: String) -> URL {
        MeetingStore.dir.appendingPathComponent(meetingID, isDirectory: true)
    }

    static func url(_ meetingID: String, _ fileName: String) -> URL {
        dir(meetingID).appendingPathComponent(fileName)
    }

    /// `![alt](file)` — only plain file names (no folders, no URLs) count.
    static let pattern = try! NSRegularExpression(pattern: #"!\[[^\]\n]*\]\(([A-Za-z0-9_.-]+\.(?:png|jpg|jpeg|gif|heic|tiff))\)"#)

    /// File names referenced by a notes string, in order.
    static func references(in text: String) -> [String] {
        pattern.matches(in: text, range: NSRange(text.startIndex..., in: text)).compactMap {
            Range($0.range(at: 1), in: text).map { String(text[$0]) }
        }
    }

    /// Replaces each picture line with `replacement(fileName)`.
    static func rewrite(_ text: String, _ replacement: (String) -> String) -> String {
        var out = ""
        var last = text.startIndex
        for m in pattern.matches(in: text, range: NSRange(text.startIndex..., in: text)) {
            guard let whole = Range(m.range, in: text), let name = Range(m.range(at: 1), in: text) else { continue }
            out += text[last..<whole.lowerBound]
            out += replacement(String(text[name]))
            last = whole.upperBound
        }
        return out + text[last...]
    }

    /// Saves a picture into the meeting's folder: scaled so the long side is at
    /// most 2400 px, PNG unless that comes out over 1.5 MB (photos) — then JPEG.
    /// Returns the file name, or nil if the data isn't a readable image.
    static func save(_ image: NSImage, meetingID: String) -> String? {
        guard let cg = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else { return nil }
        var rep = NSBitmapImageRep(cgImage: cg)
        let longSide = max(rep.pixelsWide, rep.pixelsHigh)
        if longSide > 2400 {
            let scale = 2400 / CGFloat(longSide)
            let w = Int(CGFloat(rep.pixelsWide) * scale), h = Int(CGFloat(rep.pixelsHigh) * scale)
            if let scaled = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: w, pixelsHigh: h, bitsPerSample: 8,
                                             samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                             colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0) {
                NSGraphicsContext.saveGraphicsState()
                NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: scaled)
                NSGraphicsContext.current?.imageInterpolation = .high
                NSImage(cgImage: cg, size: .zero).draw(in: NSRect(x: 0, y: 0, width: w, height: h))
                NSGraphicsContext.restoreGraphicsState()
                rep = scaled
            }
        }
        var data = rep.representation(using: .png, properties: [:])
        var ext = "png"
        if let png = data, png.count > 1_500_000,
           let jpg = rep.representation(using: .jpeg, properties: [.compressionFactor: 0.85]) {
            data = jpg
            ext = "jpg"
        }
        guard let data else { return nil }
        let name = UUID().uuidString.lowercased() + "." + ext
        do {
            try FileManager.default.createDirectory(at: dir(meetingID), withIntermediateDirectories: true)
            try data.write(to: url(meetingID, name), options: .atomic)
            return name
        } catch {
            log("meetings: couldn't save picture: \(error)")
            return nil
        }
    }

    static func attachment(meetingID: String, fileName: String) -> MeetingImageAttachment? {
        guard let image = NSImage(contentsOf: url(meetingID, fileName)) else { return nil }
        let a = MeetingImageAttachment()
        a.fileName = fileName
        a.image = image
        var size = image.size
        if size.width > maxDisplayWidth {
            size = NSSize(width: maxDisplayWidth, height: size.height * maxDisplayWidth / size.width)
        }
        a.bounds = CGRect(origin: .zero, size: size)
        return a
    }

    /// Notes Markdown → editor text, with pictures shown inline.
    static func attributed(_ text: String, meetingID: String,
                           attributes: [NSAttributedString.Key: Any]) -> NSAttributedString {
        let out = NSMutableAttributedString()
        var last = text.startIndex
        for m in pattern.matches(in: text, range: NSRange(text.startIndex..., in: text)) {
            guard let whole = Range(m.range, in: text), let name = Range(m.range(at: 1), in: text),
                  let a = attachment(meetingID: meetingID, fileName: String(text[name])) else { continue }
            out.append(NSAttributedString(string: String(text[last..<whole.lowerBound]), attributes: attributes))
            let pic = NSMutableAttributedString(attachment: a)
            pic.addAttributes(attributes, range: NSRange(location: 0, length: pic.length))
            out.append(pic)
            last = whole.upperBound
        }
        out.append(NSAttributedString(string: String(text[last...]), attributes: attributes))
        return out
    }

    /// Editor text → notes Markdown.
    static func markdown(_ s: NSAttributedString) -> String {
        var out = ""
        let ns = s.string as NSString
        s.enumerateAttribute(.attachment, in: NSRange(location: 0, length: s.length)) { value, range, _ in
            if let a = value as? MeetingImageAttachment {
                out += String(repeating: "![](\(a.fileName))", count: range.length)
            } else {
                out += ns.substring(with: range).replacingOccurrences(of: "\u{FFFC}", with: "")
            }
        }
        return out
    }

    /// Images on a pasteboard that should be pasted AS pictures. Text wins when
    /// there's real text too — Office and some browsers put an image rendering
    /// of copied text on the pasteboard alongside it.
    static func images(on pb: NSPasteboard) -> [NSImage] {
        let imageTypes = [UTType.image.identifier]
        if let urls = pb.readObjects(forClasses: [NSURL.self],
                                     options: [.urlReadingFileURLsOnly: true,
                                               .urlReadingContentsConformToTypes: imageTypes]) as? [URL],
           !urls.isEmpty {
            return urls.compactMap { NSImage(contentsOf: $0) }
        }
        if let text = pb.string(forType: .string)?.trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty {
            let looksLikeLink = !text.contains(where: \.isWhitespace) && (text.hasPrefix("http") || text.hasPrefix("file:"))
            if !looksLikeLink { return [] }
        }
        guard pb.canReadObject(forClasses: [NSImage.self], options: nil) else { return [] }
        return (pb.readObjects(forClasses: [NSImage.self], options: nil) as? [NSImage]) ?? []
    }

    /// Rich clipboard copy of notes: pictures included (RTFD), plus plain text.
    static func writeRich(_ markdown: String, meetingID: String, to pb: NSPasteboard) {
        pb.clearContents()
        let attr = attributed(markdown, meetingID: meetingID,
                              attributes: [.font: NSFont.systemFont(ofSize: 14), .foregroundColor: NSColor.black])
        if !references(in: markdown).isEmpty,
           let rtfd = attr.rtfd(from: NSRange(location: 0, length: attr.length), documentAttributes: [:]) {
            pb.setData(rtfd, forType: .rtfd)
        }
        pb.setString(rewrite(markdown) { _ in "[picture]" }, forType: .string)
    }
}

/// The notes editor: plain text, except that pasted or dropped pictures land
/// inline (saved to the meeting's folder via `saveImage`).
final class NotesTextView: NSTextView {
    /// Saves a picture for the open meeting; returns the inline attachment.
    var saveImage: ((NSImage) -> MeetingImageAttachment?)?

    private static let imageTypes: [NSPasteboard.PasteboardType] = [.fileURL, .png, .tiff]

    override var readablePasteboardTypes: [NSPasteboard.PasteboardType] {
        // Only plain text besides images — styled text pastes as plain.
        guard isEditable, saveImage != nil else { return [.string] }
        return Self.imageTypes + [.string]
    }

    override var acceptableDragTypes: [NSPasteboard.PasteboardType] { readablePasteboardTypes }

    override func readSelection(from pboard: NSPasteboard) -> Bool {
        if insertImages(from: pboard) { return true }
        return super.readSelection(from: pboard)
    }

    override func readSelection(from pboard: NSPasteboard, type: NSPasteboard.PasteboardType) -> Bool {
        if insertImages(from: pboard) { return true }
        if type != .string, let s = pboard.string(forType: .string) {
            insertText(s, replacementRange: selectedRange())
            return true
        }
        return super.readSelection(from: pboard, type: type)
    }

    /// Each picture goes on its own line.
    private func insertImages(from pb: NSPasteboard) -> Bool {
        guard isEditable, let saveImage else { return false }
        let images = MeetingImages.images(on: pb)
        guard !images.isEmpty else { return false }
        let pics = NSMutableAttributedString()
        for img in images {
            guard let a = saveImage(img) else { continue }
            if pics.length > 0 { pics.append(NSAttributedString(string: "\n", attributes: typingAttributes)) }
            let p = NSMutableAttributedString(attachment: a)
            p.addAttributes(typingAttributes, range: NSRange(location: 0, length: p.length))
            pics.append(p)
        }
        guard pics.length > 0 else { return false }
        let range = selectedRange()
        let ns = string as NSString
        if range.location > 0, ns.character(at: range.location - 1) != 0x0A {
            pics.insert(NSAttributedString(string: "\n", attributes: typingAttributes), at: 0)
        }
        let end = range.location + range.length
        if end >= ns.length || ns.character(at: end) != 0x0A {
            pics.append(NSAttributedString(string: "\n", attributes: typingAttributes))
        }
        guard shouldChangeText(in: range, replacementString: pics.string) else { return false }
        textStorage?.replaceCharacters(in: range, with: pics)
        didChangeText()
        setSelectedRange(NSRange(location: range.location + pics.length, length: 0))
        return true
    }
}
