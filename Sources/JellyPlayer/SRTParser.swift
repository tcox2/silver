import Foundation

struct SubtitleCue: Sendable { let start: Double; let end: Double; let text: String }

enum SRTParser {
    static func parse(_ source: String) -> [SubtitleCue] {
        source.replacingOccurrences(of: "\r\n", with: "\n").components(separatedBy: "\n\n").compactMap { block in
            let lines = block.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
            guard let index = lines.firstIndex(where: { $0.contains(" --> ") }) else { return nil }
            let times = lines[index].components(separatedBy: " --> ")
            guard times.count == 2, let start = seconds(times[0]), let end = seconds(times[1]) else { return nil }
            let text = lines.dropFirst(index + 1).joined(separator: "\n")
                .replacingOccurrences(of: "<[^>]+>", with: "", options: .regularExpression)
            return SubtitleCue(start: start, end: end, text: text)
        }
    }

    private static func seconds(_ value: String) -> Double? {
        let parts = value.replacingOccurrences(of: ",", with: ".").split(separator: ":")
        guard parts.count == 3, let h = Double(parts[0]), let m = Double(parts[1]), let s = Double(parts[2]) else { return nil }
        return h * 3600 + m * 60 + s
    }
}
