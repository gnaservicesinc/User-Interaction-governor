import AppKit
import Foundation
import GovernorCore
import GovonerStudioCore

struct UGLComponentStatus: Identifiable {
    let component: UGLComponent
    let bundledVersion: String
    let installedVersion: String?
    let comparison: UGLVersionComparison

    var id: String { component.id }

    var statusText: String {
        switch comparison {
        case .missing: return "Not installed"
        case .older: return "Update available"
        case .current: return "Current"
        case .newer: return "Newer than bundled"
        case .unknown: return "Version unknown"
        }
    }
}

@MainActor
final class UGLInstallationManager: ObservableObject {
    @Published var layout: UGLInstallLayout {
        didSet {
            installPath = savedPath(for: layout)
            UserDefaults.standard.set(layout.rawValue, forKey: Keys.layout)
            refresh()
        }
    }
    @Published var installPath: String {
        didSet {
            UserDefaults.standard.set(installPath, forKey: Self.pathKey(for: layout))
            refresh()
        }
    }
    @Published private(set) var statuses: [UGLComponentStatus] = []
    @Published private(set) var isWorking = false
    @Published var message: String?

    private enum Keys {
        static let layout = "UGLInstallLayout"
        static let prefix = "UGLPrefixPath"
        static let framework = "UGLFrameworkPath"
    }

    init() {
        let defaults = UserDefaults.standard
        let initialLayout = defaults.string(forKey: Keys.layout).flatMap(UGLInstallLayout.init(rawValue:)) ?? .prefix
        layout = initialLayout
        installPath = defaults.string(forKey: Self.pathKey(for: initialLayout)) ?? Self.defaultPath(for: initialLayout)
        refresh()
    }

    var location: UGLInstallLocation {
        UGLInstallLocation(layout: layout, selectedPath: installPath)
    }

    var exportRuntimePath: String { location.runtimeURL.path }
    var pathEntry: String { location.pathEntry }

    var actionTitle: String {
        if statuses.contains(where: { $0.comparison == .older }) { return "Update UGL" }
        if statuses.contains(where: { $0.comparison == .missing || $0.comparison == .unknown }) { return "Install UGL" }
        return "Repair Installation"
    }

    var isInstalled: Bool { statuses.contains { $0.comparison != .missing } }
    var bundledComponentsAvailable: Bool { uglComponents.allSatisfy { bundledURL(for: $0) != nil } }

    func resetPath() {
        installPath = Self.defaultPath(for: layout)
    }

    func refresh() {
        guard installPath.first == "/" else {
            statuses = uglComponents.map {
                UGLComponentStatus(component: $0, bundledVersion: governorVersion, installedVersion: nil, comparison: .missing)
            }
            return
        }
        let currentLocation = location
        statuses = uglComponents.map { component in
            let installedURL = currentLocation.installedURL(for: component)
            let exists = FileManager.default.fileExists(atPath: installedURL.path)
            let version = exists ? installedVersion(for: component, at: currentLocation) : nil
            return UGLComponentStatus(
                component: component,
                bundledVersion: governorVersion,
                installedVersion: version,
                comparison: exists ? (version == nil ? .unknown : compareUGLVersion(installed: version)) : .missing
            )
        }
    }

    func install() {
        perform(title: "UGL was installed successfully.") { try self.installScript() }
    }

    func uninstall() {
        perform(title: "UGL was removed from the selected location.") { try self.uninstallScript() }
    }

    func revealInstallation() {
        NSWorkspace.shared.activateFileViewerSelecting([location.payloadRoot])
    }

    private func perform(title: String, script: @escaping () throws -> String) {
        guard !isWorking else { return }
        isWorking = true
        message = nil
        do {
            let command = try script()
            let usesAdministrator = Self.needsAdministrator(for: location.root.path)
            Task {
                do {
                    try await Task.detached {
                        try Self.runShell(command, withAdministratorPrivileges: usesAdministrator)
                    }.value
                    message = title
                } catch {
                    message = error.localizedDescription
                }
                isWorking = false
                refresh()
            }
        } catch {
            message = error.localizedDescription
            isWorking = false
        }
    }

    private func installScript() throws -> String {
        guard bundledComponentsAvailable else {
            throw UGLInstallError("This copy of Govoner Studio does not contain a complete UGL component bundle. Rebuild or reinstall the app.")
        }
        return try UGLInstallPlan.installScript(
            location: location,
            bundledRoot: Bundle.main.bundleURL.appendingPathComponent("Contents/Components", isDirectory: true)
        )
    }

    private func uninstallScript() throws -> String {
        try UGLInstallPlan.uninstallScript(location: location)
    }

    private func bundledURL(for component: UGLComponent) -> URL? {
        let components = Bundle.main.bundleURL.appendingPathComponent("Contents/Components", isDirectory: true)
        let candidate = UGLInstallPlan.bundledURL(for: component, under: components)
        return FileManager.default.fileExists(atPath: candidate.path) ? candidate : nil
    }

    private func installedVersion(for component: UGLComponent, at location: UGLInstallLocation) -> String? {
        if let value = try? String(contentsOf: location.versionURL(for: component), encoding: .utf8)
            .trimmingCharacters(in: .whitespacesAndNewlines), !value.isEmpty {
            return value
        }
        let installed = location.installedURL(for: component)
        switch component.kind {
        case .executable:
            guard let output = try? Self.capture(installed, arguments: ["--version"]) else { return nil }
            return output.split(whereSeparator: { $0 == " " || $0 == "\n" }).last.map(String.init)
        case .bashRuntime:
            guard let source = try? String(contentsOf: installed, encoding: .utf8),
                  let range = source.range(of: #"GOVONER_BASH_RUNTIME_VERSION=([0-9.]+)"#, options: .regularExpression) else { return nil }
            return String(source[range]).split(separator: "=", maxSplits: 1).last.map(String.init)
        }
    }

    private static func defaultPath(for layout: UGLInstallLayout) -> String {
        layout == .prefix ? UGLInstallLocation.defaultPrefix : UGLInstallLocation.defaultFramework
    }

    private static func pathKey(for layout: UGLInstallLayout) -> String {
        layout == .prefix ? Keys.prefix : Keys.framework
    }

    private func savedPath(for layout: UGLInstallLayout) -> String {
        UserDefaults.standard.string(forKey: Self.pathKey(for: layout)) ?? Self.defaultPath(for: layout)
    }

    nonisolated private static func needsAdministrator(for path: String) -> Bool {
        var candidate = URL(fileURLWithPath: path, isDirectory: true)
        let manager = FileManager.default
        while candidate.path != "/", !manager.fileExists(atPath: candidate.path) {
            candidate.deleteLastPathComponent()
        }
        return !manager.isWritableFile(atPath: candidate.path)
    }

    nonisolated private static func runShell(_ script: String, withAdministratorPrivileges: Bool) throws {
        if withAdministratorPrivileges {
            let escaped = script.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"")
            _ = try capture(URL(fileURLWithPath: "/usr/bin/osascript"), arguments: ["-e", "do shell script \"\(escaped)\" with administrator privileges"])
        } else {
            _ = try capture(URL(fileURLWithPath: "/bin/bash"), arguments: ["-c", script])
        }
    }

    nonisolated private static func capture(_ executable: URL, arguments: [String]) throws -> String {
        let result = try ProcessCapture.run(executable, arguments: arguments)
        let outputData = result.output
        let errorData = result.error
        guard result.status == 0 else {
            let detail = String(data: errorData, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines)
            throw UGLInstallError(detail?.isEmpty == false ? detail! : "The install command exited with status \(result.status).")
        }
        return String(data: outputData, encoding: .utf8) ?? ""
    }

}

private struct UGLInstallError: LocalizedError {
    let text: String
    init(_ text: String) { self.text = text }
    var errorDescription: String? { text }
}
