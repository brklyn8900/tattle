import Foundation

/// The shape every LLM answer must take. Appended to every prompt and shown read-only in
/// Settings: editing it would silently break the knowledge base.
enum OutputContract {
    static let schema = """
        {
          "type": "object",
          "description": "For a host, purpose, why and care must not say which program on this Mac opened it or that one is running: the answer is shown on every connection to the host.",
          "properties": {
            "owner": {
              "type": "string",
              "description": "Who runs the host, publishes the process, or installed the item. Omit if unknown."
            },
            "purpose": {
              "type": "string",
              "description": "One or two plain sentences: what this is."
            },
            "why": {
              "type": "string",
              "description": "One plain sentence: why an item like this is probably on a Mac."
            },
            "category": {
              "type": "string",
              "description": "One or two words, such as: system, sync, update, telemetry, advertising, cdn, developer-tool, media."
            },
            "risk": {
              "type": "string",
              "enum": ["low", "medium", "high"],
              "description": "How much the owner should care. Telemetry and ad networks are medium; unknown binaries phoning home are high."
            },
            "confidence": {
              "type": "string",
              "enum": ["low", "medium", "high"],
              "description": "How sure you are. Low when guessing from the name alone."
            },
            "care": {
              "type": "string",
              "description": "One plain sentence: why the owner should care or need not, in line with risk. Do not open with yes or no; the app adds that from risk."
            },
            "suggestedPattern": {
              "type": "string",
              "description": "Optional glob that would cover sibling items, such as p*-caldav.icloud.com. Never applied automatically."
            }
          },
          "required": ["purpose", "why", "care", "risk", "confidence"]
        }
        """
}

/// A parsed answer. Lenient about the wrapping, strict about the fields a rule cannot do
/// without: an answer missing `why` or `care` is kept, and the page shows the app's words alone.
struct LLMAnswer: Equatable, Sendable {
    var owner: String?
    var purpose: String
    var why: String?
    var care: String?
    var category: String?
    var risk: Rule.Level
    var confidence: Rule.Level
    var suggestedPattern: String?

    enum ParseError: Error, Equatable {
        case noJSON
        case missing(String)
        case badValue(String)
    }

    /// Accepts the bare object, the `claude -p --output-format json` envelope (`result`
    /// string or `structured_output` object), a fenced code block, or an object at the end
    /// of chatter from an agent CLI.
    static func parse(_ output: String) throws -> LLMAnswer {
        guard let object = extractObject(from: output) else { throw ParseError.noJSON }
        if let inner = object["structured_output"] as? [String: Any] {
            return try fromObject(inner)
        }
        if let inner = object["result"] as? String, object["purpose"] == nil {
            return try parse(inner)
        }
        return try fromObject(object)
    }

    private static func fromObject(_ object: [String: Any]) throws -> LLMAnswer {
        guard let purpose = (object["purpose"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines),
              !purpose.isEmpty else { throw ParseError.missing("purpose") }
        return LLMAnswer(
            owner: optionalString(object["owner"]),
            purpose: purpose,
            why: optionalString(object["why"]),
            care: optionalString(object["care"]),
            category: optionalString(object["category"]),
            risk: try level(object["risk"], field: "risk"),
            confidence: try level(object["confidence"], field: "confidence"),
            suggestedPattern: optionalString(object["suggestedPattern"]))
    }

    private static func optionalString(_ value: Any?) -> String? {
        guard let string = (value as? String)?.trimmingCharacters(in: .whitespacesAndNewlines),
              !string.isEmpty else { return nil }
        return string
    }

    private static func level(_ value: Any?, field: String) throws -> Rule.Level {
        guard let string = value as? String else { throw ParseError.missing(field) }
        guard let level = Rule.Level(rawValue: string.lowercased()) else {
            throw ParseError.badValue(field)
        }
        return level
    }

    /// The first JSON object that parses, trying the whole text, then each `{` to the
    /// matching `}` from the end of the text backwards.
    private static func extractObject(from text: String) -> [String: Any]? {
        if let object = decode(text) { return object }
        let chars = Array(text.utf8)
        var depth = 0
        var end: Int?
        for index in stride(from: chars.count - 1, through: 0, by: -1) {
            switch chars[index] {
            case UInt8(ascii: "}"):
                if depth == 0 { end = index }
                depth += 1
            case UInt8(ascii: "{"):
                depth -= 1
                if depth == 0, let end,
                   let candidate = String(bytes: chars[index...end], encoding: .utf8),
                   let object = decode(candidate) {
                    return object
                }
            default:
                break
            }
        }
        return nil
    }

    private static func decode(_ text: String) -> [String: Any]? {
        guard let data = text.trimmingCharacters(in: .whitespacesAndNewlines).data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return nil }
        return object
    }
}
