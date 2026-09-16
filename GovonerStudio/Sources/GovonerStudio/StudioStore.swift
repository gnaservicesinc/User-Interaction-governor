import Foundation
import GovernorCore
import GovonerStudioCore

@MainActor
final class StudioStore: ObservableObject {
    @Published var project: StudioProject {
        didSet { persistLastProject() }
    }
    @Published var selection: UUID?
    @Published var previewStatus = "Ready"
    @Published var previewUUID: String?

    init() {
        project = Self.loadLastProject() ?? .starter
        selection = project.steps.first?.id
    }

    func newProject() {
        project = .starter
        selection = project.steps.first?.id
        previewStatus = "Ready"
        previewUUID = nil
    }

    @discardableResult
    func add(_ type: UIType, at index: Int? = nil) -> UUID {
        let step = StudioStep.template(for: type)
        let destination = min(max(index ?? project.steps.count, 0), project.steps.count)
        project.steps.insert(step, at: destination)
        selection = step.id
        return step.id
    }

    func removeSelected() {
        guard let selection,
              let index = project.steps.firstIndex(where: { $0.id == selection }) else { return }
        project.steps.remove(at: index)
        self.selection = project.steps.indices.contains(index)
            ? project.steps[index].id
            : project.steps.last?.id
    }

    func duplicateSelected() {
        guard let selection,
              let index = project.steps.firstIndex(where: { $0.id == selection }) else { return }
        var copy = project.steps[index]
        copy.id = UUID()
        project.steps.insert(copy, at: index + 1)
        self.selection = copy.id
    }

    func move(stepID: UUID, before targetID: UUID) {
        guard stepID != targetID,
              let source = project.steps.firstIndex(where: { $0.id == stepID }),
              let target = project.steps.firstIndex(where: { $0.id == targetID }) else { return }
        let step = project.steps.remove(at: source)
        let adjustedTarget = source < target ? target - 1 : target
        project.steps.insert(step, at: adjustedTarget)
    }

    func moveToEnd(stepID: UUID) {
        guard let source = project.steps.firstIndex(where: { $0.id == stepID }),
              source != project.steps.index(before: project.steps.endIndex) else { return }
        let step = project.steps.remove(at: source)
        project.steps.append(step)
    }

    func load(_ project: StudioProject) {
        self.project = project
        selection = project.steps.first?.id
        previewStatus = "Project opened"
        previewUUID = nil
    }

    func moveStep(_ stepID: UUID, by offset: Int) {
        guard let source = project.steps.firstIndex(where: { $0.id == stepID }),
              project.steps.indices.contains(source + offset) else { return }
        let step = project.steps.remove(at: source)
        project.steps.insert(step, at: source + offset)
        selection = stepID
    }

    func bash(runtimePath: String = BashExporter.defaultRuntimePath) throws -> String {
        try BashExporter.export(project, runtimePath: runtimePath)
    }

    private static var autosaveURL: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Govoner Studio", isDirectory: true)
            .appendingPathComponent("LastProject.govonerstudio")
    }

    private static func loadLastProject() -> StudioProject? {
        guard let data = try? Data(contentsOf: autosaveURL) else { return nil }
        return try? JSONDecoder().decode(StudioProject.self, from: data)
    }

    private func persistLastProject() {
        let url = Self.autosaveURL
        do {
            try FileManager.default.createDirectory(
                at: url.deletingLastPathComponent(),
                withIntermediateDirectories: true,
                attributes: nil
            )
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            try encoder.encode(project).write(to: url, options: .atomic)
        } catch {
            // Explicit saves still report errors. Autosave is intentionally best effort.
        }
    }
}
