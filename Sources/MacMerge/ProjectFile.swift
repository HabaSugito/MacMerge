import AppKit
import UniformTypeIdentifiers

/// A saved comparison (`.macmerge`, JSON): the paths, the file filter and the compare options,
/// so the same comparison can be opened again later.
struct ProjectFile: Codable {
    var left: String
    var right: String
    var middle: String?
    var output: String?
    var kind: CompareTarget.Kind
    var fileFilter: String?
    var whitespace: String?
    var ignoreCase: Bool?
    var ignoreBlankLines: Bool?
    var ignoreLineEndings: Bool?
    var detectMovedBlocks: Bool?
    var lineFilters: String?

    init(target: CompareTarget) {
        left = target.left.path(percentEncoded: false)
        right = target.right.path(percentEncoded: false)
        middle = target.middle?.path(percentEncoded: false)
        output = target.output?.path(percentEncoded: false)
        kind = target.kind
        let d = UserDefaults.standard
        fileFilter = CompareSettings.fileFilter
        whitespace = d.string(forKey: CompareSettings.whitespaceKey)
        ignoreCase = d.bool(forKey: CompareSettings.ignoreCaseKey)
        ignoreBlankLines = d.bool(forKey: CompareSettings.ignoreBlankLinesKey)
        ignoreLineEndings = d.bool(forKey: CompareSettings.ignoreLineEndingsKey)
        detectMovedBlocks = d.bool(forKey: CompareSettings.detectMovedBlocksKey)
        lineFilters = d.string(forKey: CompareSettings.lineFiltersKey)
    }

    var target: CompareTarget {
        CompareTarget(left: URL(filePath: left), right: URL(filePath: right),
                      middle: middle.map { URL(filePath: $0) }, output: output.map { URL(filePath: $0) }, kind: kind)
    }

    /// Puts the project's filter and options into effect.
    func applySettings() {
        let d = UserDefaults.standard
        if let fileFilter { d.set(fileFilter, forKey: CompareSettings.fileFilterKey) }
        if let whitespace { d.set(whitespace, forKey: CompareSettings.whitespaceKey) }
        if let ignoreCase { d.set(ignoreCase, forKey: CompareSettings.ignoreCaseKey) }
        if let ignoreBlankLines { d.set(ignoreBlankLines, forKey: CompareSettings.ignoreBlankLinesKey) }
        if let ignoreLineEndings { d.set(ignoreLineEndings, forKey: CompareSettings.ignoreLineEndingsKey) }
        if let detectMovedBlocks { d.set(detectMovedBlocks, forKey: CompareSettings.detectMovedBlocksKey) }
        if let lineFilters { d.set(lineFilters, forKey: CompareSettings.lineFiltersKey) }
    }

    @MainActor
    static func save(_ target: CompareTarget) {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = "\(target.left.deletingPathExtension().lastPathComponent).macmerge"
        panel.allowedContentTypes = [.json]
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
            try encoder.encode(ProjectFile(target: target)).write(to: url, options: .atomic)
        } catch {
            NSAlert(error: error).runModal()
        }
    }

    @MainActor
    static func open() -> CompareTarget? {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.json]
        panel.message = "MacMerge のプロジェクトファイル（.macmerge）を選んでください"
        guard panel.runModal() == .OK, let url = panel.url else { return nil }
        return load(url)
    }

    @MainActor
    static func load(_ url: URL) -> CompareTarget? {
        do {
            let project = try JSONDecoder().decode(ProjectFile.self, from: Data(contentsOf: url))
            project.applySettings()
            return project.target
        } catch {
            let alert = NSAlert()
            alert.messageText = "プロジェクトファイルを読み込めませんでした"
            alert.informativeText = error.localizedDescription
            alert.runModal()
            return nil
        }
    }
}
