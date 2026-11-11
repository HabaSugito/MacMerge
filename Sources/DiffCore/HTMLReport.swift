import Foundation

/// Self-contained HTML reports of comparisons.
public enum HTMLReport {
    private static func L(_ value: String.LocalizationValue) -> String { String(localized: value) }

    /// The language the report is written in, for the page's lang attribute.
    private static var language: String { Bundle.main.preferredLocalizations.first ?? "en" }

    private static func head() -> String {
        "<!doctype html><html lang=\"\(language)\"><head><meta charset=\"utf-8\"><title>\(escape(L("MacMerge Report")))</title><style>\(style)</style></head><body>"
    }

    public static func escape(_ s: String) -> String {
        var out = ""
        out.reserveCapacity(s.count)
        for c in s {
            switch c {
            case "&": out += "&amp;"
            case "<": out += "&lt;"
            case ">": out += "&gt;"
            case "\"": out += "&quot;"
            case "\t": out += "    "
            default: out.append(c)
            }
        }
        return out
    }

    private static let style = """
    body{font:13px -apple-system,sans-serif;margin:24px;color:#222}
    h1{font-size:18px}p.meta{color:#666}
    table{border-collapse:collapse;width:100%}
    th,td{border:1px solid #ddd;padding:2px 6px;vertical-align:top}
    th{background:#f2f2f2;text-align:left}
    td.code{font:12px ui-monospace,Menlo,monospace;white-space:pre-wrap}
    td.num{color:#888;text-align:right;font:11px ui-monospace,Menlo,monospace;width:1%}
    .diff{background:#efcb05}.ghost{background:#c0c0c0}.ignored{background:#fbf2bf}
    .moved{background:#e49b52}.word{background:#f1e2ad}
    .identical{color:#2a7a2a}.different{color:#b35c00}.only{color:#777}.error{color:#c00}
    """

    /// A side-by-side report of one file comparison.
    public static func fileComparison(leftTitle: String, rightTitle: String, left: [String], right: [String],
                                      comparison: LineComparison, options: CompareOptions = .standard) -> String {
        var html = head()
        html += "<h1>\(escape(L("File Comparison Report")))</h1><p class=\"meta\">\(escape(L("\(comparison.hunks.count) differences"))) · \(escape(Date().formatted()))</p>"
        html += "<table><tr><th colspan=2>\(escape(leftTitle))</th><th colspan=2>\(escape(rightTitle))</th></tr>"
        for row in comparison.rows {
            let cls: String
            if row.hunk != nil { cls = "diff" } else if row.isIgnored { cls = "ignored" } else { cls = "" }
            var inline: (left: [NSRange], right: [NSRange]) = ([], [])
            if row.hunk != nil, let l = row.left, let r = row.right {
                inline = inlineDifferences(left[l], right[r], options: options)
            }
            for (line, lines, ranges, moved) in [(row.left, left, inline.left, comparison.movedLeft), (row.right, right, inline.right, comparison.movedRight)] {
                if let line {
                    let c = moved[line] != nil ? "moved" : cls
                    html += "<td class=\"num\">\(line + 1)</td><td class=\"code \(c)\">\(highlight(lines[line], ranges))</td>"
                } else {
                    html += "<td class=\"num\"></td><td class=\"code \(row.hunk != nil ? "ghost" : "")\"></td>"
                }
            }
            html += "</tr>"
        }
        return html + "</table></body></html>"
    }

    private static func highlight(_ line: String, _ ranges: [NSRange]) -> String {
        guard !ranges.isEmpty else { return escape(line) }
        let ns = line as NSString
        var out = "", pos = 0
        for r in ranges where r.location >= pos && NSMaxRange(r) <= ns.length {
            out += escape(ns.substring(with: NSRange(location: pos, length: r.location - pos)))
            out += "<span class=\"word\">" + escape(ns.substring(with: r)) + "</span>"
            pos = NSMaxRange(r)
        }
        return out + escape(ns.substring(from: pos))
    }

    /// A table of every item in a folder comparison.
    public static func folderComparison(left: URL, right: URL, items: [FolderItem]) -> String {
        var html = head()
        html += "<h1>\(escape(L("Folder Comparison Report")))</h1><p class=\"meta\">\(escape(L("Left"))): \(escape(left.path))<br>\(escape(L("Right"))): \(escape(right.path))<br>\(escape(Date().formatted()))</p>"
        let headers = [L("Path"), L("Result"), L("Left Modified"), L("Right Modified"), L("Left Size"), L("Right Size")]
        html += "<table><tr>" + headers.map { "<th>\(escape($0))</th>" }.joined() + "</tr>"
        func walk(_ list: [FolderItem], _ prefix: String) {
            for item in list {
                let path = prefix + item.name + (item.isDirectory ? "/" : "")
                let (text, cls) = describe(item.result)
                html += "<tr><td>\(escape(path))</td><td class=\"\(cls)\">\(escape(text))</td>"
                html += "<td>\(item.left?.modified?.formatted() ?? "")</td><td>\(item.right?.modified?.formatted() ?? "")</td>"
                html += "<td>\(item.isDirectory ? "" : item.left.map { "\($0.size)" } ?? "")</td><td>\(item.isDirectory ? "" : item.right.map { "\($0.size)" } ?? "")</td></tr>"
                if let children = item.children { walk(children, path) }
            }
        }
        walk(items, "")
        return html + "</table></body></html>"
    }

    public static func describe(_ result: CompareResult) -> (text: String, cssClass: String) {
        switch result {
        case .identical: return (L("Identical"), "identical")
        case .different(0): return (L("Different (line endings or encoding only)"), "different")
        case .different(let n?): return (L("Different (\(n))"), "different")
        case .different: return (L("Different"), "different")
        case .leftOnly: return (L("Left only"), "only")
        case .rightOnly: return (L("Right only"), "only")
        case .binaryIdentical: return (L("Binary: identical"), "identical")
        case .binaryDifferent: return (L("Binary: different"), "different")
        case .error(let m): return (L("Error: \(m)"), "error")
        case .moved(let other): return (L("Renamed or moved: \(other)"), "different")
        }
    }
}
