import Foundation
import SwiftUI

struct RecentProjectMenuItems: View {
    let urls: [URL]
    let open: (URL) -> Void
    let clear: () -> Void

    var body: some View {
        if urls.isEmpty {
            Text("No Recent Projects")
        } else {
            ForEach(urls, id: \.self) { url in
                Button {
                    open(url)
                } label: {
                    Text(menuTitle(for: url))
                }
                .help(url.path)
            }
            Divider()
            Button("Clear Recent Projects", action: clear)
        }
    }

    private func menuTitle(for url: URL) -> String {
        let name = url.deletingPathExtension().lastPathComponent
        let duplicates = urls.filter { $0.deletingPathExtension().lastPathComponent == name }
        return duplicates.count > 1 ? "\(name) — \(url.deletingLastPathComponent().path)" : name
    }
}
