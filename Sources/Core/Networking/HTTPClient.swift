import Foundation

/// Minimal async HTTP layer for provider adapters. Maps transport failures onto
/// `ProviderError` so raw `URLError`s never leak upward, and keeps request URLs
/// out of logs (they contain Xtream credentials).
public struct HTTPClient: @unchecked Sendable {  // URLSession is thread-safe

    public struct Config: Sendable {
        public var timeout: TimeInterval
        public var maxResponseBytes: Int
        public init(timeout: TimeInterval = 30, maxResponseBytes: Int = 200 * 1_024 * 1_024) {
            self.timeout = timeout
            self.maxResponseBytes = maxResponseBytes
        }
    }

    private let session: URLSession
    private let config: Config

    /// `protocolClasses` lets tests answer requests with a stub `URLProtocol`
    /// (a fake provider) instead of the network.
    public init(config: Config = .init(), protocolClasses: [AnyClass] = []) {
        self.config = config
        let configuration = URLSessionConfiguration.ephemeral
        if !protocolClasses.isEmpty {
            configuration.protocolClasses = protocolClasses + (configuration.protocolClasses ?? [])
        }
        configuration.timeoutIntervalForRequest = config.timeout
        configuration.timeoutIntervalForResource = config.timeout * 4
        configuration.waitsForConnectivity = false
        configuration.httpAdditionalHeaders = ["User-Agent": "Aeria/1.0 (tvOS)"]
        self.session = URLSession(configuration: configuration)
    }

    /// GET the URL and return the raw body. Throws `ProviderError`.
    public func data(from url: URL) async throws -> Data {
        do {
            let (data, response) = try await session.data(from: url)
            try validate(response, data: data)
            return data
        } catch let error as ProviderError {
            throw error
        } catch {
            throw ProviderError.from(error)
        }
    }

    /// Download a (potentially large) resource to a temporary file instead of
    /// holding it all in memory. `URLSession` transparently gzip-inflates into
    /// the file. **The caller owns the returned file and must delete it.**
    public func downloadToFile(from url: URL) async throws -> URL {
        do {
            let (tempURL, response) = try await session.download(from: url)
            do {
                try validateStatus(response)
                let attrs = try? FileManager.default.attributesOfItem(atPath: tempURL.path)
                if let size = attrs?[.size] as? Int, size > config.maxResponseBytes {
                    throw ProviderError.badResponse
                }

                let dest = FileManager.default.temporaryDirectory
                    .appendingPathComponent("aeria-dl-\(UUID().uuidString).tmp")
                try? FileManager.default.removeItem(at: dest)
                try FileManager.default.moveItem(at: tempURL, to: dest)
                return dest
            } catch {
                try? FileManager.default.removeItem(at: tempURL)
                throw error
            }
        } catch let error as ProviderError {
            throw error
        } catch {
            throw ProviderError.from(error)
        }
    }

    /// GET + JSON-decode. Xtream panels sometimes return `""` or `false` for
    /// "no content" — callers should tolerate `nil`.
    public func decode<T: Decodable>(_ type: T.Type, from url: URL) async throws -> T {
        let data = try await self.data(from: url)
        do {
            return try JSONDecoder().decode(T.self, from: data)
        } catch {
            AppLog.provider.error("JSON decode failed for \(AppLog.redacting(url), privacy: .public)")
            throw ProviderError.badResponse
        }
    }

    private func validate(_ response: URLResponse, data: Data) throws {
        try validateStatus(response)
        if data.count > config.maxResponseBytes { throw ProviderError.badResponse }
    }

    private func validateStatus(_ response: URLResponse) throws {
        guard let http = response as? HTTPURLResponse else { return }
        switch http.statusCode {
        case 200...299:            return
        case 401, 403:             throw ProviderError.authenticationFailed
        case 404, 400:             throw ProviderError.badResponse
        case 408, 429, 500...599:  throw ProviderError.cannotReachProvider
        default:                   throw ProviderError.badResponse
        }
    }
}
