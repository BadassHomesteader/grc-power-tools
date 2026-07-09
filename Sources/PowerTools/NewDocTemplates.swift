import Foundation
import AppKit

/// "New Document" in Finder — the Windows right-click gap. macOS has a native
/// (undocumented) mechanism: any file dropped in
///   ~/Library/Application Support/com.apple.finder/New Document Templates/
/// appears in Finder's right-click "New Document" submenu, creating a copy in
/// the current folder. We seed it with blank Word / Excel / Text / RTF /
/// Markdown templates so the switcher gets their familiar "New ▸ Word Document".
///
/// The Office files are minimal-but-valid OOXML packages (a .docx / .xlsx is a
/// zip of XML parts); we build the part tree and zip it with /usr/bin/zip.
enum NewDocTemplates {
    static var folder: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/com.apple.finder/New Document Templates", isDirectory: true)
    }

    /// Seed the templates (overwriting ours) and relaunch Finder so the menu
    /// picks them up. Returns the installed file names.
    @discardableResult
    static func install() throws -> [String] {
        let fm = FileManager.default
        try fm.createDirectory(at: folder, withIntermediateDirectories: true)

        var installed: [String] = []
        // Plain-text kinds: a byte or two of valid content each.
        try write("Text Document.txt", "")
        try write("Markdown Document.md", "")
        try write("Rich Text Document.rtf", #"{\rtf1\ansi\ansicpg1252\cocoartf2639 {\fonttbl\f0\fswiss Helvetica;}\f0\fs24 \cf0 }"#)
        installed += ["Text Document.txt", "Markdown Document.md", "Rich Text Document.rtf"]

        try zipOOXML(named: "Word Document.docx", parts: docxParts)
        try zipOOXML(named: "Excel Workbook.xlsx", parts: xlsxParts)
        installed += ["Word Document.docx", "Excel Workbook.xlsx"]

        return installed
    }

    /// Relaunch Finder so a freshly-seeded folder shows up in the menu.
    static func relaunchFinder() {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/killall")
        p.arguments = ["Finder"]
        try? p.run()
        p.waitUntilExit()
    }

    // MARK: Writing

    private static func write(_ name: String, _ contents: String) throws {
        try contents.data(using: .utf8)?.write(to: folder.appendingPathComponent(name))
    }

    /// Build the OOXML part tree in a temp dir, then zip it into `named`.
    private static func zipOOXML(named: String, parts: [String: String]) throws {
        let fm = FileManager.default
        let tmp = fm.temporaryDirectory.appendingPathComponent("ptooxml-\(named)")
        try? fm.removeItem(at: tmp)
        try fm.createDirectory(at: tmp, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: tmp) }

        for (path, xml) in parts {
            let dest = tmp.appendingPathComponent(path)
            try fm.createDirectory(at: dest.deletingLastPathComponent(), withIntermediateDirectories: true)
            try xml.data(using: .utf8)!.write(to: dest)
        }

        let out = folder.appendingPathComponent(named)
        try? fm.removeItem(at: out)
        let zip = Process()
        zip.executableURL = URL(fileURLWithPath: "/usr/bin/zip")
        zip.currentDirectoryURL = tmp
        zip.arguments = ["-q", "-r", "-X", out.path, "."]
        try zip.run()
        zip.waitUntilExit()
        guard zip.terminationStatus == 0 else {
            throw NSError(domain: "NewDocTemplates", code: Int(zip.terminationStatus),
                          userInfo: [NSLocalizedDescriptionKey: "zip failed for \(named)"])
        }
    }

    // MARK: Minimal OOXML

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
