import SwiftUI

/// Signing in, and the one alternative to it.
///
/// This used to open on a choice of three, local first, and most of the screen
/// was a download manager. A model on this Mac is gone — it got documents wrong
/// quietly — so the screen opens on the thing nearly everyone should use, and
/// bringing your own key is a disclosure at the bottom for the people who want
/// it.
struct ModelSettings: View {
    @AppStorage("ai.backend") private var backend = ModelConnector.Backend.sketchyworks.rawValue
    @AppStorage("ai.openRouterModel") private var openRouterModel = "anthropic/claude-sonnet-4.5"

    @State private var showAdvanced = false
    @State private var flow = OAuthFlow()
    @State private var connecting = false
    @State private var problem: String?
    @State private var balance: String?
    /// The sign-in is stored but the service won't take it.
    ///
    /// A token in the keychain is not the same as an account that answers, and the
    /// difference is invisible in the one place you'd go to check: a green tick
    /// and no balance underneath, because the balance call failed and said nothing.
    @State private var expired = false
    /// Bumped after connect/disconnect so the Keychain is re-read; the credential is
    /// deliberately not held in a property, or "Disconnect" wouldn't take effect.
    @State private var credentialsRevision = 0

    /// A stored "ollama" no longer resolves, so anyone who had it lands here.
    private var chosen: ModelConnector.Backend {
        ModelConnector.Backend(rawValue: backend) ?? .sketchyworks
    }

    var body: some View {
        Form {
            Section {
                sketchyworksSection
            } header: {
                Text("Sketchyworks account")
            } footer: {
                Text("Everything else in Sketchyworks is free. Credits pay for the "
                     + "few things that need a model: removing something out of a "
                     + "picture, extending one, vectorizing, and AI Draw.")
                    .font(.caption).foregroundStyle(.secondary)
            }

            Section(isExpanded: $showAdvanced) {
                Toggle("Use my OpenRouter key instead", isOn: Binding(
                    get: { chosen == .openRouter },
                    set: { backend = ($0 ? ModelConnector.Backend.openRouter
                                          : .sketchyworks).rawValue }))
                if chosen == .openRouter { openRouterSection }
            } header: {
                Text("Advanced")
            }

            if let problem {
                Label(problem, systemImage: "exclamationmark.triangle")
                    .font(.caption).foregroundStyle(.orange)
            }
        }
        .formStyle(.grouped)
        .padding(4)
        .task { Credentials.migrateLegacyDefaults() }
        .onAppear { showAdvanced = chosen == .openRouter }
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
            Text("Signing in creates a key scoped to Sketchyworks — we never see your "
                 + "password, and you can revoke it from OpenRouter at any time. "
                 + "Requests are billed to your account.")
                .font(.caption).foregroundStyle(.secondary)
        }
    }

    private var sketchyworksSection: some View {
        Group {
            account(connected: Credentials.has(.sketchyworksToken),
                    connectedLabel: "Signed in to Sketchyworks",
                    connectLabel: "Sign in to Sketchyworks…",
                    connect: { try await flow.connect(.sketchyworks(base: ModelConnector.Settings().sketchyworksHost)) },
                    disconnect: { Credentials.set(.sketchyworksToken, nil) })
            Text("Nothing to download and no second account to set up. What you ask "
                 + "about is sent to our service to be worked on.")
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
                    Label(expired ? "Sign-in expired" : connectedLabel,
                          systemImage: expired ? "exclamationmark.triangle.fill" : "checkmark.circle.fill")
                        .foregroundStyle(expired ? .orange : .green)
                    if connectedLabel.contains("Sketchyworks") {
                        if expired {
                            Text("The service didn't accept this sign-in. Disconnect and sign in again.")
                                .font(.caption).foregroundStyle(.secondary)
                        } else if let balance {
                            Text(balance)
                                .font(.caption).foregroundStyle(.secondary)
                        }
                        Link("Buy credits", destination: ModelConnector.creditsURL)
                            .font(.caption)
                    }
                }
                .task(id: credentialsRevision) {
                    guard connectedLabel.contains("Sketchyworks") else { return }
                    // Ask the service who this is. Swallowing the answer is what let a
                    // dead token look like a healthy account until something else
                    // failed and blamed itself.
                    do {
                        let me = try await ModelConnector.accountBalance()
                        balance = "\(me.email) · \(ModelConnector.credits(me.credits)) left"
                        expired = false
                    } catch ModelConnector.Failure.notSignedIn {
                        balance = nil
                        expired = true
                    } catch {
                        // Offline or the service is down: not the same as rejected,
                        // and calling it expired would send someone to sign in again
                        // for no reason.
                        balance = nil
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

}
