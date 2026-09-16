import Foundation
import GovernorCore

public struct UGLComponent: Identifiable, Equatable, Sendable {
    public enum Kind: String, Sendable {
        case executable = "Executable"
        case bashRuntime = "Bash runtime"
    }

    public let id: String
    public let displayName: String
    public let kind: Kind

    public init(id: String, displayName: String, kind: Kind) {
        self.id = id
        self.displayName = displayName
        self.kind = kind
    }
}

public let uglComponents: [UGLComponent] = [
    UGLComponent(id: "uig", displayName: "uig client", kind: .executable),
    UGLComponent(id: "uigd", displayName: "uigd service", kind: .executable),
    UGLComponent(id: "uig-renderer", displayName: "uig renderer", kind: .executable),
    UGLComponent(id: "ui-display", displayName: "Display wrapper", kind: .executable),
    UGLComponent(id: "ui-choice", displayName: "Choice wrapper", kind: .executable),
    UGLComponent(id: "ui-entry", displayName: "Entry wrapper", kind: .executable),
    UGLComponent(id: "ui-confirm", displayName: "Confirm wrapper", kind: .executable),
    UGLComponent(id: "ui-file", displayName: "File wrapper", kind: .executable),
    UGLComponent(id: "ui-media", displayName: "Media wrapper", kind: .executable),
    UGLComponent(id: "govoner-runtime", displayName: "Shared Govoner Bash runtime", kind: .bashRuntime),
]

public enum UGLInstallLayout: String, CaseIterable, Identifiable, Sendable {
    case prefix
    case framework

    public var id: String { rawValue }
    public var title: String { self == .prefix ? "Unix Prefix" : "macOS Framework" }
}

public struct UGLInstallLocation: Equatable, Sendable {
    public static let defaultPrefix = "/usr/local"
    public static let defaultFramework = "/Library/Frameworks/UGL.framework"

    public let layout: UGLInstallLayout
    public let selectedPath: String

    public init(layout: UGLInstallLayout, selectedPath: String) {
        self.layout = layout
        self.selectedPath = selectedPath
    }

    public var root: URL { URL(fileURLWithPath: selectedPath, isDirectory: true).standardizedFileURL }

    public var payloadRoot: URL {
        switch layout {
        case .prefix: return root
        case .framework: return root.appendingPathComponent("Versions/A", isDirectory: true)
        }
    }

    public var binDirectory: URL {
        payloadRoot.appendingPathComponent("bin", isDirectory: true)
    }

    public var libraryDirectory: URL {
        switch layout {
        case .prefix:
            return payloadRoot.appendingPathComponent("lib/ugl", isDirectory: true)
        case .framework:
            return payloadRoot.appendingPathComponent("Resources", isDirectory: true)
        }
    }

    public var metadataDirectory: URL {
        libraryDirectory.appendingPathComponent("versions", isDirectory: true)
    }

    public var runtimeURL: URL {
        let root = layout == .framework
            ? self.root.appendingPathComponent("Versions/Current/Resources", isDirectory: true)
            : libraryDirectory
        return root.appendingPathComponent("govoner-runtime.sh")
    }

    public var pathEntry: String {
        switch layout {
        case .prefix: return binDirectory.path
        case .framework: return root.appendingPathComponent("Versions/Current/bin", isDirectory: true).path
        }
    }

    public func installedURL(for component: UGLComponent) -> URL {
        switch component.kind {
        case .executable: return binDirectory.appendingPathComponent(component.id)
        case .bashRuntime: return libraryDirectory.appendingPathComponent("govoner-runtime.sh")
        }
    }

    public func versionURL(for component: UGLComponent) -> URL {
        metadataDirectory.appendingPathComponent(component.id + ".version")
    }
}

public enum UGLVersionComparison: String, Sendable {
    case missing
    case older
    case current
    case newer
    case unknown
}

public func compareUGLVersion(installed: String?, bundled: String = governorVersion) -> UGLVersionComparison {
    guard let installed, !installed.isEmpty else { return .missing }
    guard installed.range(of: #"^[0-9]+(?:\.[0-9]+)*$"#, options: .regularExpression) != nil,
          bundled.range(of: #"^[0-9]+(?:\.[0-9]+)*$"#, options: .regularExpression) != nil else {
        return installed == bundled ? .current : .unknown
    }
    let result = installed.compare(bundled, options: .numeric)
    switch result {
    case .orderedAscending: return .older
    case .orderedSame: return .current
    case .orderedDescending: return .newer
    }
}

public enum UGLInstallPlan {
    public static func bundledURL(for component: UGLComponent, under root: URL) -> URL {
        switch component.kind {
        case .executable: return root.appendingPathComponent("bin/\(component.id)")
        case .bashRuntime: return root.appendingPathComponent("share/govoner-runtime.sh")
        }
    }

    public static func installScript(
        location: UGLInstallLocation,
        bundledRoot: URL,
        version: String = governorVersion
    ) throws -> String {
        try validate(location)
        var lines = ["set -eu"]
        if location.layout == .framework {
            let current = location.root.appendingPathComponent("Versions/Current").path
            lines.append("if [ -e \(shellQuote(current)) ] && [ ! -L \(shellQuote(current)) ]; then echo 'UGL.framework Versions/Current is not a symlink' >&2; exit 1; fi")
        }
        lines.append("/bin/mkdir -p \(shellQuote(location.binDirectory.path)) \(shellQuote(location.libraryDirectory.path)) \(shellQuote(location.metadataDirectory.path))")
        for component in uglComponents {
            let source = bundledURL(for: component, under: bundledRoot)
            guard FileManager.default.fileExists(atPath: source.path) else {
                throw UGLInstallationPlanError("Bundled component \(component.id) is missing.")
            }
            let target = location.installedURL(for: component)
            let mode = component.kind == .executable ? "755" : "644"
            lines.append("/usr/bin/install -m \(mode) \(shellQuote(source.path)) \(shellQuote(target.path))")
            lines.append("/usr/bin/printf '%s\\n' \(shellQuote(version)) > \(shellQuote(location.versionURL(for: component).path))")
        }
        let manifest = location.libraryDirectory.appendingPathComponent("components.manifest")
        lines.append("/usr/bin/printf '%s\\n' \(shellQuote(uglComponents.map(\.id).joined(separator: "\n"))) > \(shellQuote(manifest.path))")
        if location.layout == .framework {
            let versions = location.root.appendingPathComponent("Versions", isDirectory: true)
            lines.append("/bin/ln -sfn A \(shellQuote(versions.appendingPathComponent("Current").path))")
            lines.append("/bin/ln -sfn Versions/Current/bin \(shellQuote(location.root.appendingPathComponent("bin").path))")
            lines.append("/bin/ln -sfn Versions/Current/Resources \(shellQuote(location.root.appendingPathComponent("Resources").path))")
        }
        return lines.joined(separator: "\n")
    }

    public static func uninstallScript(location: UGLInstallLocation) throws -> String {
        try validate(location)
        var lines = ["set -eu"]
        for component in uglComponents {
            lines.append("/bin/rm -f -- \(shellQuote(location.installedURL(for: component).path)) \(shellQuote(location.versionURL(for: component).path))")
        }
        lines.append("/bin/rm -f -- \(shellQuote(location.libraryDirectory.appendingPathComponent("components.manifest").path))")
        if location.layout == .framework {
            lines.append("[ \"$(/usr/bin/readlink \(shellQuote(location.root.appendingPathComponent("Versions/Current").path)) 2>/dev/null || true)\" != A ] || /bin/rm -f -- \(shellQuote(location.root.appendingPathComponent("Versions/Current").path))")
            lines.append("/bin/rm -f -- \(shellQuote(location.root.appendingPathComponent("bin").path)) \(shellQuote(location.root.appendingPathComponent("Resources").path))")
        }
        for directory in [location.metadataDirectory, location.libraryDirectory, location.binDirectory, location.payloadRoot] {
            lines.append("/bin/rmdir \(shellQuote(directory.path)) 2>/dev/null || true")
        }
        if location.layout == .prefix {
            lines.append("/bin/rmdir \(shellQuote(location.payloadRoot.appendingPathComponent("lib").path)) 2>/dev/null || true")
            lines.append("/bin/rmdir \(shellQuote(location.payloadRoot.path)) 2>/dev/null || true")
        }
        if location.layout == .framework {
            lines.append("/bin/rmdir \(shellQuote(location.root.appendingPathComponent("Versions").path)) 2>/dev/null || true")
            lines.append("/bin/rmdir \(shellQuote(location.root.path)) 2>/dev/null || true")
        }
        return lines.joined(separator: "\n")
    }

    private static func validate(_ location: UGLInstallLocation) throws {
        let path = location.selectedPath
        guard path.first == "/", !path.contains("\n"), !path.contains("\r"), !path.contains("\0") else {
            throw UGLInstallationPlanError("Choose an absolute installation path.")
        }
        guard location.root.path != "/" else {
            throw UGLInstallationPlanError("The filesystem root cannot be used as an installation prefix.")
        }
        if location.layout == .framework, !location.root.path.hasSuffix(".framework") {
            throw UGLInstallationPlanError("A Framework installation path must end in .framework.")
        }
    }

    private static func shellQuote(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: "'\"'\"'") + "'"
    }
}

public struct UGLInstallationPlanError: LocalizedError, Equatable, Sendable {
    public let message: String
    public init(_ message: String) { self.message = message }
    public var errorDescription: String? { message }
}
