import AppKit
import UniformTypeIdentifiers

/// Saves generated text (patches, reports) where the user chooses.
@MainActor
enum Exporter {
    static func save(_ text: String, suggestedName: String, type: UTType, openAfterSaving: Bool = false) {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = suggestedName
        panel.allowedContentTypes = [type]
        panel.canCreateDirectories = true
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            try text.write(to: url, atomically: true, encoding: .utf8)
            if openAfterSaving { NSWorkspace.shared.open(url) }
        } catch {
            NSAlert(error: error).runModal()
        }
    }

    static func saveReport(_ html: String) {
        save(html, suggestedName: "MacMerge レポート.html", type: .html, openAfterSaving: true)
    }

    static func savePatch(_ patch: String) {
        guard !patch.isEmpty else {
            let alert = NSAlert()
            alert.messageText = "差分がないため、パッチは作成されませんでした"
            alert.runModal()
            return
        }
        save(patch, suggestedName: "changes.patch", type: UTType(filenameExtension: "patch") ?? .plainText)
    }
}
