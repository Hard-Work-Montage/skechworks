import AccompliceCore
import SwiftUI

/// A command bar, not a chat window.
///
/// The interaction is: say what you want, see exactly what it proposes, apply it.
/// A conversation would invite open-ended requests the operations can't express;
/// one line and a visible plan keeps the failure mode "that isn't what I meant"
/// rather than "what did it just do to my file".
struct CommandBar: View {
    @EnvironmentObject var store: DocumentStore
    @Environment(\.dismiss) private var dismiss

    @AppStorage("ai.backend") private var backend = ModelConnector.Backend.ollama.rawValue
    @AppStorage("ai.ollamaHost") private var ollamaHost = "http://127.0.0.1:11434"
    @AppStorage("ai.model") private var model = "qwen3-coder:30b"
    @AppStorage("ai.openRouterKey") private var openRouterKey = ""
    @AppStorage("ai.openRouterModel") private var openRouterModel = "anthropic/claude-sonnet-4.5"

    @State private var request = ""
    @State private var thinking = false
    @State private var proposal: [DocumentCommand] = []
    @State private var rawReply = ""
    @State private var problem: String?
    @FocusState private var focused: Bool

    private var settings: ModelConnector.Settings {
        var s = ModelConnector.Settings()
        s.backend = ModelConnector.Backend(rawValue: backend) ?? .ollama
        s.ollamaHost = ollamaHost
        s.model = model
        s.openRouterKey = openRouterKey
        s.openRouterModel = openRouterModel
        return s
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 8) {
                Image(systemName: "sparkles").foregroundStyle(.secondary)
                TextField("Rename these to coin-{i}… · Delete every path narrower than 4…",
                          text: $request)
                    .textFieldStyle(.plain)
                    .font(.title3)
                    .focused($focused)
                    .onSubmit(ask)
                if thinking { ProgressView().controlSize(.small) }
            }
            .padding(12)
            .background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 8))

            HStack(spacing: 6) {
                Text(settings.backend == .ollama ? model : openRouterModel)
                    .font(.caption).foregroundStyle(.secondary)
                Text("·").foregroundStyle(.tertiary)
                Text(settings.backend.title).font(.caption).foregroundStyle(.tertiary)
                Spacer()
                Text("\(store.selection.count) selected").font(.caption).foregroundStyle(.tertiary)
            }

            if let problem {
                Text(problem)
                    .font(.callout).foregroundStyle(.orange)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }

            if !proposal.isEmpty {
                Divider()
                // Show the plan before touching anything. This is the whole point.
                Text("Proposed").font(.caption2.weight(.semibold))
                    .foregroundStyle(.tertiary).tracking(0.6)
                ScrollView {
                    VStack(alignment: .leading, spacing: 4) {
                        ForEach(Array(proposal.enumerated()), id: \.offset) { _, c in
                            HStack(spacing: 6) {
                                Image(systemName: "arrow.turn.down.right")
                                    .font(.caption2).foregroundStyle(.tertiary)
                                Text(c.summary).font(.callout)
                                Text(describe(c.query)).font(.caption).foregroundStyle(.secondary)
                            }
                        }
                    }
                }
                .frame(maxHeight: 120)

                HStack {
                    Button("Discard") { proposal = []; rawReply = "" }
                    Spacer()
                    Button("Apply") {
                        let report = store.run(proposal)
                        store.status = report.replacingOccurrences(of: "\n", with: " · ")
                        proposal = []
                        dismiss()
                    }
                    .keyboardShortcut(.defaultAction)
                }
            }
        }
        .padding(16)
        .frame(width: 560)
        .onAppear { focused = true }
    }

    private func describe(_ q: LayerQuery) -> String {
        var bits: [String] = []
        if let v = q.type { bits.append(v) }
        if let v = q.name { bits.append("named “\(v)”") }
        if let v = q.fill { bits.append("filled \(v)") }
        if let v = q.text { bits.append("text “\(v)”") }
        if q.selectedOnly == true { bits.append("in selection") }
        if let v = q.limit { bits.append("max \(v)") }
        return bits.isEmpty ? "everything on the page" : bits.joined(separator: ", ")
    }

    private func ask() {
        let text = request.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, !thinking else { return }
        thinking = true
        problem = nil
        proposal = []
        let document = store.describeDocument()
        let connector = ModelConnector(settings: settings)

        Task { @MainActor in
            do {
                let result = try await connector.plan(request: text, document: document)
                proposal = result.commands
                rawReply = result.raw
            } catch {
                problem = error.localizedDescription
            }
            thinking = false
        }
    }
}
