import Foundation

/// Coarse progress phases reported by a `ProviderClient` during a bulk import,
/// so the UI can show a "Preparing your library" checklist instead of an opaque
/// spinner.
public enum ImportPhase: String, CaseIterable, Sendable, Identifiable {
    case connecting
    case channels
    case movies
    case series
    case guide
    case finalizing

    public var id: String { rawValue }

    public var label: String {
        switch self {
        case .connecting: return "Connecting to your provider"
        case .channels:   return "Channels"
        case .movies:     return "Movies"
        case .series:     return "Series"
        case .guide:      return "TV guide"
        case .finalizing: return "Tidying up"
        }
    }

    /// Phases shown as checklist rows (connecting/finalizing are implicit).
    public static var checklist: [ImportPhase] { [.channels, .movies, .series, .guide] }
}

/// A `Sendable` progress reporter handed to `ProviderClient.fetchRawCatalog`.
/// Calling it marks a phase as reached; the handler is expected to also treat
/// all earlier phases as complete.
public struct ImportProgressReporter: Sendable {
    private let handler: @Sendable (ImportPhase) -> Void
    public init(_ handler: @escaping @Sendable (ImportPhase) -> Void) {
        self.handler = handler
    }
    public func reached(_ phase: ImportPhase) { handler(phase) }

    /// A no-op reporter for callers that don't care.
    public static let ignore = ImportProgressReporter { _ in }
}
