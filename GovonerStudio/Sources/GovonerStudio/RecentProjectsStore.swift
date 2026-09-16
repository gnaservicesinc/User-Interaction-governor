import AppKit
import Combine

/// Use macOS document history so recent projects persist and follow moved files.
@MainActor
final class RecentProjectsStore: ObservableObject {
    static let shared = RecentProjectsStore()
    @Published private(set) var urls: [URL] = []

    private init() { refresh() }

    func record(_ url: URL) {
        NSDocumentController.shared.noteNewRecentDocumentURL(url)
        refresh()
    }

    func clear() {
        NSDocumentController.shared.clearRecentDocuments(nil)
        refresh()
    }

    func refresh() {
        urls = NSDocumentController.shared.recentDocumentURLs
    }
}
