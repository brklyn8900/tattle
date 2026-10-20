import Foundation

/// Builds the text sent to the provider: instructions, the item with its facts, and the
/// output contract.
enum Prompt {
    static let defaultInstructions = """
        You explain to a Mac's owner what their machine is doing. They are technical but not \
        a network engineer. You get one item (a host, a process, a listening port or a \
        startup item) and the facts the app has already established about it. Say what it \
        is and why it is probably there, in one or two plain sentences. Build on the facts: \
        never contradict them and do not restate them. If you do not know, say so and set \
        confidence to low. Reply with a single JSON object and nothing else.
        """

    static func build(instructions: String, request: ExplainRequest) -> String {
        var lines = [instructions.trimmingCharacters(in: .whitespacesAndNewlines), ""]
        lines.append("Item: \(label(for: request.kind)) \(request.key)")
        if request.facts.isEmpty {
            lines.append("Facts: none established.")
        } else {
            lines.append("Facts:")
            for fact in request.facts {
                lines.append("- \(fact.name): \(fact.value)")
            }
        }
        lines.append("")
        lines.append("Answer with one JSON object matching this schema:")
        lines.append(OutputContract.schema)
        return lines.joined(separator: "\n")
    }

    static func label(for kind: Rule.Kind) -> String {
        switch kind {
        case .host: "host"
        case .process: "process"
        case .port: "listening port"
        case .launchItem: "startup item"
        }
    }
}
