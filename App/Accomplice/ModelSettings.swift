import SwiftUI

/// Local-first, cloud optional — the same arrangement as Pelocan, and the honest one
/// for a tool whose pitch is that it runs on your machine.
///
/// The app ships with no model, so this pane has to be able to finish the setup, not
/// just describe it: check whether Ollama is running, pull the recommended model with
/// visible progress, and get out of the way once it's there.
struct ModelSettings: View {
    @AppStorage("ai.backend") private var backend = ModelConnector.Backend.ollama.rawValue
    @AppStorage("ai.ollamaHost") private var ollamaHost = "http://127.0.0.1:11434"
    @AppStorage("ai.model") private var model = LocalModel.recommended
    @AppStorage("ai.openRouterKey") private var openRouterKey = ""
    @AppStorage("ai.openRouterModel") private var openRouterModel = "anthropic/claude-sonnet-4.5"

    @StateObject private var local = LocalModel(host: "http://127.0.0.1:11434")

    var body: some View {
        Form {
            Picker("Run on", selection: $backend) {
                ForEach(ModelConnector.Backend.allCases) { Text($0.title).tag($0.rawValue) }
            }
            .pickerStyle(.radioGroup)

            if backend == ModelConnector.Backend.ollama.rawValue {
                localSection
            } else {
                SecureField("OpenRouter key", text: $openRouterKey)
                TextField("Model", text: $openRouterModel)
                Text("Your key, your account. Used only when this backend is selected.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .padding(4)
        .task(id: ollamaHost) { await local.refresh(host: ollamaHost, wanted: model) }
        .task(id: model) { await local.refresh(host: ollamaHost, wanted: model) }
    }

    @ViewBuilder
    private var localSection: some View {
        switch local.state {
        case .checking:
            HStack(spacing: 8) {
                ProgressView().controlSize(.small)
                Text("Looking for Ollama…").foregroundStyle(.secondary)
            }

        case .noOllama:
            // Two separate failures — no Ollama, and no model — used to arrive as one
            // "couldn't reach the model", which pointed at neither fix.
            VStack(alignment: .leading, spacing: 8) {
                Label("Ollama isn't running", systemImage: "exclamationmark.triangle")
                    .foregroundStyle(.orange)
                Text("Accomplice runs its model through Ollama, on your machine. "
                     + "Install it, launch it once, then come back here.")
                    .font(.caption).foregroundStyle(.secondary)
                HStack {
                    Link("Get Ollama", destination: URL(string: "https://ollama.com/download")!)
                    Button("Check again") {
                        Task { await local.refresh(host: ollamaHost, wanted: model) }
                    }
                }
                Text("Or switch to OpenRouter above and use your own key.")
                    .font(.caption).foregroundStyle(.tertiary)
            }

        case .missing:
            VStack(alignment: .leading, spacing: 8) {
                Text("Download \(model)").font(.headline)
                Text(model == LocalModel.recommended
                     ? "\(LocalModel.recommendedSize), downloaded once and kept on this machine. "
                       + "Nothing you draw or type ever leaves it."
                     : "Downloaded once through Ollama and kept on this machine.")
                    .font(.caption).foregroundStyle(.secondary)
                HStack {
                    Button("Download") { local.download(model) }
                        .buttonStyle(.borderedProminent)
                    if !local.installed.isEmpty {
                        Text("or pick one you already have, below")
                            .font(.caption).foregroundStyle(.tertiary)
                    }
                }
            }

        case .downloading(let fraction, let detail):
            VStack(alignment: .leading, spacing: 6) {
                // Real bytes, not a spinner: several gigabytes behind an indeterminate
                // spinner is indistinguishable from a hang.
                ProgressView(value: fraction > 0 ? fraction : nil, total: 1)
                HStack {
                    Text(detail).font(.caption).foregroundStyle(.secondary)
                    Spacer()
                    Button("Cancel") { local.cancelDownload() }.controlSize(.small)
                }
            }

        case .ready:
            Label("\(model) is ready", systemImage: "checkmark.circle.fill")
                .foregroundStyle(.green)

        case .failed(let why):
            VStack(alignment: .leading, spacing: 8) {
                Label(why, systemImage: "exclamationmark.triangle").foregroundStyle(.orange)
                Button("Try again") { local.download(model) }
            }
        }

        if !local.installed.isEmpty {
            Picker("Model", selection: $model) {
                ForEach(modelChoices, id: \.self) { Text($0).tag($0) }
            }
        } else {
            TextField("Model", text: $model)
        }
        TextField("Ollama host", text: $ollamaHost)
        Text("Smaller models were tried and got real documents wrong — quietly, "
             + "reporting success. Pull any model in Ollama and it'll appear here if "
             + "you'd rather trade accuracy for disk.")
            .font(.caption).foregroundStyle(.secondary)
    }

    /// Installed models, plus the recommended one even when it isn't installed yet —
    /// otherwise selecting it in order to download it is impossible.
    private var modelChoices: [String] {
        local.installed.contains(LocalModel.recommended)
            ? local.installed
            : [LocalModel.recommended] + local.installed
    }
}
