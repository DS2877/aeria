import Foundation

/// Provider failures, each with a calm, user-facing message. Raw networking
/// errors (`NSURLErrorDomain -1009` etc.) are mapped into these before they
/// ever reach the UI.
public enum ProviderError: Error, Equatable, Sendable {
    case offline
    case cannotReachProvider
    case authenticationFailed
    case emptyLibrary
    case badResponse
    case playlistMalformed(reason: String)
    case streamUnavailable
    case streamNotSupported(detail: String)
    case timedOut
    case cancelled
    case unknown

    /// Short title for an error card.
    public var title: String {
        switch self {
        case .offline:               return "Du är offline"
        case .cannotReachProvider:   return "Kan inte nå din leverantör"
        case .authenticationFailed:  return "Inloggningen misslyckades"
        case .emptyLibrary:          return "Din leverantör skickade inget"
        case .badResponse:           return "Din leverantör svarade oväntat"
        case .playlistMalformed:     return "Spellistan kunde inte läsas"
        case .streamUnavailable:     return "Kanalen är inte tillgänglig just nu"
        case .streamNotSupported:    return "Apple TV kan inte spela den här strömmen"
        case .timedOut:              return "Din leverantör svarade inte i tid"
        case .cancelled:             return "Avbrutet"
        case .unknown:               return "Något gick fel"
        }
    }

    /// One or two sentences under the title.
    public var message: String {
        switch self {
        case .offline:
            return "Kontrollera internetanslutningen och försök igen."
        case .cannotReachProvider:
            return "Vi fick ingen kontakt. Leverantören kan ligga nere, eller så är adressen fel."
        case .authenticationFailed:
            return "Användarnamnet eller lösenordet godtogs inte. Kontrollera dina leverantörsuppgifter."
        case .emptyLibrary:
            return "Anslutningen fungerade, men leverantören skickade inga kanaler, filmer eller serier. Oftast betyder det att abonnemanget inte är aktivt, eller att uppgifterna hör till en annan tjänst."
        case .badResponse:
            return "Vi nådde leverantören men kunde inte tolka svaret."
        case .playlistMalformed(let reason):
            return "Spellistan ser inte giltig ut. (\(reason))"
        case .streamUnavailable:
            return "Strömmen svarade inte. Prova en annan kanal eller försök igen senare."
        case .streamNotSupported(let detail):
            return detail
        case .timedOut:
            return "Anslutningen tog för lång tid. Försök igen om en stund."
        case .cancelled:
            return "Begäran avbröts."
        case .unknown:
            return "Försök igen. Om det fortsätter, kontrollera dina leverantörsinställningar."
        }
    }

    /// Actions an error card should offer.
    public var recoveryActions: [RecoveryAction] {
        switch self {
        case .offline:              return [.retry, .checkConnection]
        case .cannotReachProvider:  return [.retry, .editProvider]
        case .authenticationFailed: return [.editProvider]
        case .emptyLibrary:         return [.retry, .editProvider]
        case .timedOut, .streamUnavailable, .badResponse, .unknown:
            return [.retry]
        case .playlistMalformed:    return [.editProvider]
        case .streamNotSupported:   return []
        case .cancelled:            return [.retry]
        }
    }

    public enum RecoveryAction: Sendable {
        case retry
        case checkConnection
        case editProvider

        public var label: String {
            switch self {
            case .retry:           return "Försök igen"
            case .checkConnection: return "Kontrollera anslutning"
            case .editProvider:    return "Ändra leverantör"
            }
        }
    }

    /// Map an arbitrary `Error` (often a `URLError`) into a `ProviderError`.
    public static func from(_ error: Error) -> ProviderError {
        if let providerError = error as? ProviderError { return providerError }
        if error is CancellationError { return .cancelled }
        let urlError = error as? URLError
        switch urlError?.code {
        case .some(.notConnectedToInternet), .some(.dataNotAllowed):
            return .offline
        case .some(.timedOut):
            return .timedOut
        case .some(.cannotFindHost), .some(.cannotConnectToHost),
             .some(.dnsLookupFailed), .some(.networkConnectionLost):
            return .cannotReachProvider
        case .some(.userAuthenticationRequired):
            return .authenticationFailed
        case .some(.cancelled):
            return .cancelled
        default:
            return .unknown
        }
    }
}
