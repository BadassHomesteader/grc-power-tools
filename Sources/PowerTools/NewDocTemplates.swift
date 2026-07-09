import Foundation
import AppKit

/// New Document — the Windows "New ▸ Word Document" gap. macOS has no native
/// right-click "New Document" menu, so Power Tools does it with a hotkey:
/// hold + D pops a small type picker, and the chosen blank document is created
/// in the CURRENT Finder folder, then revealed and selected so you can rename it.
///
/// The Office files are minimal-but-valid OOXML packages (a .docx / .xlsx is a
/// zip of XML parts); we build the part tree and zip it with /usr/bin/zip.
enum NewDocTemplates {
    enum DocType: String, CaseIterable {
        case word = "Word Document"
        case excel = "Excel Workbook"
        case text = "Text Document"
        case rtf = "Rich Text"
        case markdown = "Markdown"

        var ext: String {
            switch self {
            case .word: return "docx"
            case .excel: return "xlsx"
            case .text: return "txt"
            case .rtf: return "rtf"
            case .markdown: return "md"
            }
        }
        var menuTitle: String { "\(rawValue).\(ext)" }
    }

    /// The folder of the frontmost Finder window (Desktop if none). Uses Apple
    /// Events — the one place Power Tools talks to another app — so the OS shows
    /// an Automation prompt for Finder the first time. nil if denied/failed.
    static func currentFinderFolder() -> URL? {
        let script = """
        tell application "Finder"
            if (count of Finder windows) > 0 then
                return POSIX path of (target of front Finder window as alias)
            else
                return POSIX path of (path to desktop)
            end if
        end tell
        """
        var err: NSDictionary?
        guard let out = NSAppleScript(source: script)?.executeAndReturnError(&err),
              let path = out.stringValue, err == nil else {
            log("newdoc: Finder folder lookup failed: \(err ?? [:])")
            return nil
        }
        return URL(fileURLWithPath: path, isDirectory: true)
    }

    /// Create a blank document of `type` in `folder`, returning its URL. Names
    /// "Untitled.<ext>", then "Untitled 2.<ext>"… to avoid clobbering.
    static func create(_ type: DocType, in folder: URL) throws -> URL {
        let dest = uniqueURL(base: "Untitled", ext: type.ext, in: folder)
        switch type {
        case .text, .markdown:
            try Data().write(to: dest)
        case .rtf:
            try #"{\rtf1\ansi\ansicpg1252\cocoartf2639{\fonttbl\f0\fswiss Helvetica;}\f0\fs24 \cf0 }"#
                .data(using: .utf8)!.write(to: dest)
        case .word:
            try zipOOXML(to: dest, parts: docxParts)
        case .excel:
            try zipOOXML(to: dest, parts: xlsxParts)
        }
        return dest
    }

    private static func uniqueURL(base: String, ext: String, in folder: URL) -> URL {
        let fm = FileManager.default
        var url = folder.appendingPathComponent("\(base).\(ext)")
        var n = 2
        while fm.fileExists(atPath: url.path) {
            url = folder.appendingPathComponent("\(base) \(n).\(ext)")
            n += 1
        }
        return url
    }

    // MARK: Minimal OOXML → zip

    private static func zipOOXML(to dest: URL, parts: [String: String]) throws {
        let fm = FileManager.default
        let tmp = fm.temporaryDirectory.appendingPathComponent("ptooxml-\(UUID().uuidString)")
        try fm.createDirectory(at: tmp, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: tmp) }
        for (path, xml) in parts {
            let p = tmp.appendingPathComponent(path)
            try fm.createDirectory(at: p.deletingLastPathComponent(), withIntermediateDirectories: true)
            try xml.data(using: .utf8)!.write(to: p)
        }
        try? fm.removeItem(at: dest)
        let zip = Process()
        zip.executableURL = URL(fileURLWithPath: "/usr/bin/zip")
        zip.currentDirectoryURL = tmp
        zip.arguments = ["-q", "-r", "-X", dest.path, "."]
        try zip.run()
        zip.waitUntilExit()
        guard zip.terminationStatus == 0 else {
            throw NSError(domain: "NewDocTemplates", code: Int(zip.terminationStatus),
                          userInfo: [NSLocalizedDescriptionKey: "zip failed"])
        }
    }

    private static let docxParts: [String: String] = [
        "[Content_Types].xml": """
        <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
        <Types xmlns="http://schemas.openxmlformats.org/package/2006/content-types">
        <Default Extension="rels" ContentType="application/vnd.openxmlformats-package.relationships+xml"/>
        <Default Extension="xml" ContentType="application/xml"/>
        <Override PartName="/word/document.xml" ContentType="application/vnd.openxmlformats-officedocument.wordprocessingml.document.main+xml"/>
        </Types>
        """,
        "_rels/.rels": """
        <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
        <Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships">
        <Relationship Id="rId1" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/officeDocument" Target="word/document.xml"/>
        </Relationships>
        """,
        "word/document.xml": """
        <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
        <w:document xmlns:w="http://schemas.openxmlformats.org/wordprocessingml/2006/main">
        <w:body><w:p/><w:sectPr/></w:body>
        </w:document>
        """,
    ]

    private static let xlsxParts: [String: String] = [
        "[Content_Types].xml": """
        <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
        <Types xmlns="http://schemas.openxmlformats.org/package/2006/content-types">
        <Default Extension="rels" ContentType="application/vnd.openxmlformats-package.relationships+xml"/>
        <Default Extension="xml" ContentType="application/xml"/>
        <Override PartName="/xl/workbook.xml" ContentType="application/vnd.openxmlformats-officedocument.spreadsheetml.sheet.main+xml"/>
        <Override PartName="/xl/worksheets/sheet1.xml" ContentType="application/vnd.openxmlformats-officedocument.spreadsheetml.worksheet+xml"/>
        </Types>
        """,
        "_rels/.rels": """
        <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
        <Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships">
        <Relationship Id="rId1" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/officeDocument" Target="xl/workbook.xml"/>
        </Relationships>
        """,
        "xl/workbook.xml": """
        <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
        <workbook xmlns="http://schemas.openxmlformats.org/spreadsheetml/2006/main" xmlns:r="http://schemas.openxmlformats.org/officeDocument/2006/relationships">
        <sheets><sheet name="Sheet1" sheetId="1" r:id="rId1"/></sheets>
        </workbook>
        """,
        "xl/_rels/workbook.xml.rels": """
        <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
        <Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships">
        <Relationship Id="rId1" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/worksheet" Target="worksheets/sheet1.xml"/>
        </Relationships>
        """,
        "xl/worksheets/sheet1.xml": """
        <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
        <worksheet xmlns="http://schemas.openxmlformats.org/spreadsheetml/2006/main">
        <sheetData/>
        </worksheet>
        """,
    ]
}
