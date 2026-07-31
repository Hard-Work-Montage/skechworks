import SwiftUI

/// Three ways to run the model, and the setup for each finishable here.
///
/// Local first, because that's the pitch and because nothing leaves the machine. But
/// an 18 GB download is a real ask, so the two account options exist for people who
/// won't spend the disk — one billed to them, one billed to us.
struct ModelSettings: View {
    @AppStorage("ai.backend") private var backend = ModelConnector.Backend.ollama.rawValue
    @AppStorage("ai.ollamaHost") private var ollamaHost = "http://127.0.0.1:11434"
    @AppStorage("ai.model") private var model = LocalModel.recommended
    @AppStorage("ai.openRouterModel") private var openRouterModel = "anthropic/claude-sonnet-4.5"

    @StateObject private var local = LocalModel(host: "http://127.0.0.1:11434")
    @State private var flow = OAuthFlow()
    @State private var connecting = false
    @State private var problem: String?
    @State private var balance: String?
    /// Bumped after connect/disconnect so the Keychain is re-read; the credential is
    /// deliberately not held in a property, or "Disconnect" wouldn't take effect.
    @State private var credentialsRevision = 0

    var body: some View {
        Form {
            Picker("Run the model", selection: $backend) {
                ForEach(ModelConnector.Backend.allCases) { option in
                    VStack(alignment: .leading) {
                        Text(option.title)
                        Text(option.detail).font(.caption).foregroundStyle(.secondary)
                    }.tag(option.rawValue)
                }
            }
            .pickerStyle(.radioGroup)

            switch ModelConnector.Backend(rawValue: backend) ?? .ollama {
            case .ollama: localSection
            case .openRouter: openRouterSection
            case .accomplice: accompliceSection
            }

            if let problem {
                Label(problem, systemImage: "exclamationmark.triangle")
                    .font(.caption).foregroundStyle(.orange)
            }
        }
        .formStyle(.grouped)
        .padding(4)
        .task { Credentials.migrateLegacyDefaults() }
        .task(id: ollamaHost) { await local.refresh(host: ollamaHost, wanted: model) }
        .task(id: model) { await local.refresh(host: ollamaHost, wanted: model) }
    }

    // MARK: - Accounts

    private var openRouterSection: some View {
        Group {
            account(connected: Credentials.has(.openRouterKey),
                    connectedLabel: "Connected to OpenRouter",
                    connectLabel: "Connect OpenRouter…",
                    connect: { try await flow.connect(.openRouter) },
                    disconnect: { Credentials.set(.openRouterKey, nil) })
            TextField("Model", text: $openRouterModel)
            Text("Signing in creates a key scoped to Accomplice — we never see your "
                 + "password, and you can revoke it from OpenRouter at any time. "
                 + "Requests are billed to your account.")
                .font(.caption).foregroundStyle(.secondary)
        }
    }

    private var accompliceSection: some View {
        Group {
            account(connected: Credentials.has(.accompliceToken),
                    connectedLabel: "Signed in to Accomplice",
                    connectLabel: "Sign in to Accomplice…",
                    connect: { try await flow.connect(.accomplice(base: ModelConnector.Settings().accompliceHost)) },
                    disconnect: { Credentials.set(.accompliceToken, nil) })
            Text("Uses Accomplice tokens, so there's nothing to download and no second "
                 + "account to set up. Your document is sent to our service to be "
                 + "edited — the on-this-Mac option is the one where it never leaves.")
                .font(.caption).foregroundStyle(.secondary)
        }
    }

    /// Connected/not is the whole state of an account option, so it gets one row that
    /// says which, and one button that does the other thing.
    private func account(connected: Bool,
                         connectedLabel: String,
                         connectLabel: String,
                         connect: @escaping () async throws -> Void,
                         disconnect: @escaping () -> Void) -> some View {
        HStack {
            if connected {
                VStack(alignment: .leading, spacing: 2) {
                    Label(connectedLabel, systemImage: "checkmark.circle.fill")
                        .foregroundStyle(.green)
                    if connectedLabel.contains("Accomplice") {
                        if let balance {
                            Text(balance)
                                .font(.caption).foregroundStyle(.secondary)
                        }
                        Link("Buy credits", destination: URL(string: "https://accomplice.ai/credits")!)
                            .font(.caption)
                    }
                }
                .task(id: credentialsRevision) {
                    guard connectedLabel.contains("Accomplice") else { return }
                    if let me = try? await ModelConnector.accountBalance() {
                        balance = "\(me.email) · $\(String(format: "%.2f", me.credits)) in credits"
                    }
                }
                Spacer()
                Button("Disconnect") {
                    disconnect()
                    credentialsRevision += 1
                }
            } else {
                if connecting {
                    ProgressView().controlSize(.small)
                    Text("Waiting for the browser…").foregroundStyle(.secondary)
                } else {
                    Button(connectLabel) {
                        problem = nil
                        connecting = true
                        Task {
                            do { try await connect() }
                            catch OAuthFlow.Failure.cancelled { }
                            catch { problem = error.localizedDescription }
                            connecting = false
                            credentialsRevision += 1
                        }
                    }
                    .buttonStyle(.borderedProminent)
                }
                Spacer()
            }
        }
        .id(credentialsRevision)
    }

    // MARK: - Local

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
                Text("Or pick one of the account options above — neither needs a download.")
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
                Button("Download") { local.download(model) }
                    .buttonStyle(.borderedProminent)
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
