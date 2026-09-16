import Foundation
import GovonerStudioCore
import SwiftUI
import UniformTypeIdentifiers

extension UTType {
    static let govonerStudioProject = UTType(exportedAs: "com.gnaservices.govoner-studio.project", conformingTo: .json)
    static let govonerBashScript = UTType(filenameExtension: "sh") ?? .plainText
}

struct StudioProjectDocument: FileDocument {
    static var readableContentTypes: [UTType] { [.govonerStudioProject, .json] }
    var project: StudioProject

    init(project: StudioProject) { self.project = project }

    init(configuration: ReadConfiguration) throws {
        guard let data = configuration.file.regularFileContents else {
            throw CocoaError(.fileReadCorruptFile)
        }
        project = try JSONDecoder().decode(StudioProject.self, from: data)
    }

    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return FileWrapper(regularFileWithContents: try encoder.encode(project))
    }
}

struct BashScriptDocument: FileDocument {
    static var readableContentTypes: [UTType] { [.govonerBashScript, .plainText] }
    var text: String

    init(text: String) { self.text = text }

    init(configuration: ReadConfiguration) throws {
        guard let data = configuration.file.regularFileContents,
              let text = String(data: data, encoding: .utf8) else {
            throw CocoaError(.fileReadCorruptFile)
        }
        self.text = text
    }

    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper {
        FileWrapper(regularFileWithContents: Data(text.utf8))
    }
}
