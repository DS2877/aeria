import Foundation

/// Parses an XMLTV document into `[RawEPGEvent]`.
///
/// URLSession transparently inflates `Content-Encoding: gzip` responses, which
/// covers the common Xtream `xmltv.php` case. A literal gzip *file* (`.xml.gz`
/// served as octet-stream) is detected and reported rather than mis-parsed.
///
/// A real provider's XMLTV is millions of programmes / hundreds of MB. Both
/// entry points take an optional `EPGWindow`-style `DateInterval`; programmes
/// outside it are skipped and never allocated, so parsing a huge feed stays
/// flat in memory. The file-based entry point additionally streams the document
/// off disk so the decompressed XML is never fully resident.
public enum XMLTVParser {

    /// Parse from an in-memory blob (used by tests and small feeds).
    public static func parse(_ data: Data, within window: DateInterval? = nil) throws -> [RawEPGEvent] {
        if data.count >= 2, data[data.startIndex] == 0x1f, data[data.startIndex + 1] == 0x8b {
            throw ProviderError.playlistMalformed(reason: "EPG is a gzip file; not yet supported")
        }
        return try run(XMLParser(data: data), window: window)
    }

    /// Stream-parse from a file on disk — for the (usually huge) provider EPG.
    /// `channels`, when given, keeps only programmes for those channel ids —
    /// the rest of a provider-wide feed is skipped while parsing, never stored.
    public static func parse(fileURL: URL, within window: DateInterval?,
                             channels: Set<String>? = nil) throws -> [RawEPGEvent] {
        if let magic = try? Data(contentsOf: fileURL, options: .mappedIfSafe).prefix(2),
           Array(magic) == [0x1f, 0x8b] as [UInt8] {
            throw ProviderError.playlistMalformed(reason: "EPG is a gzip file; not yet supported")
        }
        guard let stream = InputStream(url: fileURL) else {
            throw ProviderError.playlistMalformed(reason: "cannot open EPG file")
        }
        return try run(XMLParser(stream: stream), window: window, channels: channels)
    }

    private static func run(_ parser: XMLParser, window: DateInterval?,
                            channels: Set<String>? = nil) throws -> [RawEPGEvent] {
        let delegate = Delegate(window: window)
        delegate.channelFilter = channels
        parser.delegate = delegate
        guard parser.parse() else {
            throw ProviderError.playlistMalformed(reason: "invalid XMLTV")
        }
        return delegate.events
    }

    // MARK: - SAX delegate

    private final class Delegate: NSObject, XMLParserDelegate {
        private(set) var events: [RawEPGEvent] = []
        var channelFilter: Set<String>?

        private let windowStart: Date?
        private let windowEnd: Date?

        private var currentChannel: String?
        private var currentStart: Date?
        private var currentStop: Date?
        private var currentElement: String?
        private var title = ""
        private var subtitle = ""
        private var desc = ""
        private var category = ""

        /// One reusable formatter — the naive version allocated one per
        /// programme, which for a million-event feed is a real cost.
        private let dateFormatter: DateFormatter = {
            let f = DateFormatter()
            f.locale = Locale(identifier: "en_US_POSIX")
            f.dateFormat = "yyyyMMddHHmmss"
            return f
        }()

        init(window: DateInterval?) {
            self.windowStart = window?.start
            self.windowEnd = window?.end
            super.init()
        }

        func parser(_ parser: XMLParser, didStartElement elementName: String,
                    namespaceURI: String?, qualifiedName qName: String?,
                    attributes attributeDict: [String: String]) {
            currentElement = elementName
            if elementName == "programme" {
                currentChannel = attributeDict["channel"]
                currentStart = parseDate(attributeDict["start"])
                currentStop = parseDate(attributeDict["stop"])
                title = ""; subtitle = ""; desc = ""; category = ""
            }
        }

        func parser(_ parser: XMLParser, foundCharacters string: String) {
            switch currentElement {
            case "title":     title += string
            case "sub-title": subtitle += string
            case "desc":      desc += string
            case "category":  if category.isEmpty { category += string }
            default: break
            }
        }

        func parser(_ parser: XMLParser, didEndElement elementName: String,
                    namespaceURI: String?, qualifiedName qName: String?) {
            if elementName == "programme" {
                if let channel = currentChannel, let start = currentStart, let stop = currentStop,
                   stop > start, overlapsWindow(start: start, stop: stop),
                   channelFilter?.contains(channel) ?? true {
                    events.append(RawEPGEvent(
                        channelID: channel,
                        title: title.trimmingCharacters(in: .whitespacesAndNewlines).ifEmpty("Programme"),
                        subtitle: subtitle.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty,
                        description: desc.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty,
                        start: start,
                        stop: stop,
                        category: category.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty
                    ))
                }
                currentChannel = nil; currentStart = nil; currentStop = nil
            }
            currentElement = nil
        }

        private func overlapsWindow(start: Date, stop: Date) -> Bool {
            if let windowStart, stop <= windowStart { return false }
            if let windowEnd, start >= windowEnd { return false }
            return true
        }

        /// XMLTV timestamps: `20240115203000 +0100` (offset optional).
        private func parseDate(_ raw: String?) -> Date? {
            guard let raw = raw?.trimmingCharacters(in: .whitespaces), raw.count >= 14 else { return nil }
            let digits = String(raw.prefix(14))

            let tzPart = raw.dropFirst(14).trimmingCharacters(in: .whitespaces)
            if tzPart.count == 5, let hours = Int(tzPart.prefix(3)), let mins = Int(tzPart.suffix(2)) {
                dateFormatter.timeZone = TimeZone(secondsFromGMT: hours * 3600 + (hours < 0 ? -mins : mins) * 60)
            } else {
                dateFormatter.timeZone = TimeZone(identifier: "UTC")
            }
            return dateFormatter.date(from: digits)
        }
    }
}

private extension String {
    func ifEmpty(_ fallback: String) -> String { isEmpty ? fallback : self }
    var nilIfEmpty: String? { isEmpty ? nil : self }
}
