import AccompliceCore
import Foundation
import Network

/// A local MCP endpoint, so Claude Code and friends can drive Accomplice directly.
///
/// The in-app chat is for when you don't want a second tool running. This is for the
/// opposite case — you're already in Claude Code, and the design file is just another
/// thing in the workspace. Both go through DocumentAPI, so neither can do anything the
/// other can't, and everything either does is one undo away.
///
/// Loopback only. It is bound to 127.0.0.1 and refuses anything else: this speaks for
/// your documents with no authentication, and that's only acceptable if nothing off
/// the machine can reach it.
@MainActor
final class MCPServer {
    static let shared = MCPServer()

    static let defaultPort: UInt16 = 31173
    private(set) var port: UInt16 = MCPServer.defaultPort
    private(set) var running = false
    /// Why it isn't running, when it isn't. Silent failure here means an agent that
    /// simply can't connect with nothing to look at.
    private(set) var lastError: String?

    private var listener: NWListener?

    private init() {}

    /// The document commands act on: whichever window is frontmost.
    private var store: DocumentStore? { AppDelegate.shared?.active }

    func start(port: UInt16 = MCPServer.defaultPort) {
        stop()
        self.port = port
        guard let nwPort = NWEndpoint.Port(rawValue: port) else {
            lastError = "bad port"
            return
        }
        do {
            let params = NWParameters.tcp
            params.allowLocalEndpointReuse = true
            // Bind to loopback by pinning the local endpoint. Passing `on:` as well
            // conflicts with this and the listener never comes up.
            params.requiredLocalEndpoint = .hostPort(host: .ipv4(.loopback), port: nwPort)
            let l = try NWListener(using: params)
            l.stateUpdateHandler = { [weak self] state in
                Task { @MainActor in
                    switch state {
                    case .ready:
                        self?.running = true
                        self?.lastError = nil
                    case .failed(let e), .waiting(let e):
                        self?.running = false
                        self?.lastError = e.localizedDescription
                    case .cancelled:
                        self?.running = false
                    default:
                        break
                    }
                }
            }
            l.newConnectionHandler = { [weak self] conn in
                conn.start(queue: .main)
                Task { @MainActor in self?.serve(conn) }
            }
            l.start(queue: .main)
            listener = l
        } catch {
            lastError = error.localizedDescription
            running = false
        }
    }

    func stop() {
        listener?.cancel()
        listener = nil
        running = false
    }

    // MARK: - Wire

    private func serve(_ conn: NWConnection) {
        conn.receive(minimumIncompleteLength: 1, maximumLength: 1 << 20) { [weak self] data, _, done, _ in
            guard let self, let data, !data.isEmpty else {
                if done { conn.cancel() }
                return
            }
            Task { @MainActor in
                let response = self.handle(request: data)
                conn.send(content: response, completion: .contentProcessed { _ in
                    conn.cancel()
                })
            }
        }
    }

    private func handle(request: Data) -> Data {
        let text = String(decoding: request, as: UTF8.self)
        guard let bodyStart = text.range(of: "\r\n\r\n") else { return http(#"{"error":"bad request"}"#) }
        let body = String(text[bodyStart.upperBound...])
        guard let json = try? JSONSerialization.jsonObject(with: Data(body.utf8)) as? [String: Any] else {
            return http(#"{"error":"expected JSON"}"#)
        }

        let id = json["id"] ?? NSNull()
        let method = json["method"] as? String ?? ""
        let params = json["params"] as? [String: Any] ?? [:]

        switch method {
        case "initialize":
            return rpc(id, [
                "protocolVersion": "2024-11-05",
                "capabilities": ["tools": [:] as [String: Any]],
                "serverInfo": ["name": "accomplice", "version": "0.1"],
            ])

        case "tools/list":
            return rpc(id, ["tools": Self.tools])

        case "tools/call":
            let name = params["name"] as? String ?? ""
            let args = params["arguments"] as? [String: Any] ?? [:]
            let result = call(name, args)
            return rpc(id, ["content": [["type": "text", "text": result]]])

        case "notifications/initialized":
            return http("")

        default:
            return rpc(id, ["content": [["type": "text", "text": "unknown method \(method)"]]])
        }
    }

    // MARK: - Tools

    private func call(_ name: String, _ args: [String: Any]) -> String {
        guard let store else { return "No document is open in Accomplice." }
        switch name {
        case "describe_document":
            return store.describeDocument()

        case "run_commands":
            // Same executor the chat and the UI use, so an agent can't reach past the
            // API — and every batch is one undo step.
            let commands: [DocumentCommand]
            if let list = args["commands"] {
                commands = (try? JSONSerialization.data(withJSONObject: list))
                    .map { DocumentCommand.decodeList($0) } ?? []
            } else {
                commands = []
            }
            guard !commands.isEmpty else { return "No valid commands. Schema:\n\(DocumentCommand.schema)" }
            return store.run(commands)

        case "find_layers":
            guard let page = store.page else { return "No page." }
            let data = (try? JSONSerialization.data(withJSONObject: args["where"] ?? args)) ?? Data()
            let q = (try? JSONDecoder().decode(LayerQuery.self, from: data)) ?? LayerQuery()
            let ids = page.find(q, selection: store.selection)
            let named = ids.compactMap { page.layer($0) }.map { "\($0.apiType) “\($0.name)”" }
            return named.isEmpty ? "No matching layers." : named.joined(separator: "\n")

        case "export_svg":
            guard let page = store.page else { return "No page." }
            let svg = SVGWriter(images: store.images).svg(page: page)
            return svg.count > 200_000 ? "SVG is \(svg.count) bytes — too large to inline. Use File ▸ Export." : svg

        case "list_pages":
            return (store.source?.pages ?? []).enumerated()
                .map { "\($0.offset): \($0.element.name) (\($0.element.layerCount) layers)" }
                .joined(separator: "\n")

        case "select_page":
            guard let i = args["index"] as? Int else { return "index required" }
            store.pageIndex = i
            return "Now on page \(i)."

        case "schema":
            return DocumentCommand.schema

        default:
            return "Unknown tool \(name)."
        }
    }

    private static let tools: [[String: Any]] = [
        [
            "name": "describe_document",
            "description": "The open document: pages, selection, and the layer tree with names, types, sizes and fills. Geometry is summarised, never dumped.",
            "inputSchema": ["type": "object", "properties": [:] as [String: Any]],
        ],
        [
            "name": "find_layers",
            "description": "Find layers by name, type, fill, stroke, text, visibility or width without changing anything.",
            "inputSchema": ["type": "object", "properties": [
                "name": ["type": "string"], "type": ["type": "string"],
                "fill": ["type": "string"], "text": ["type": "string"],
                "selectedOnly": ["type": "boolean"],
            ]],
        ],
        [
            "name": "run_commands",
            "description": "Apply a batch of edits as a single undo step. Call `schema` for the command vocabulary.",
            "inputSchema": ["type": "object", "properties": [
                "commands": ["type": "array", "items": ["type": "object"]],
            ], "required": ["commands"]],
        ],
        [
            "name": "schema",
            "description": "The command vocabulary accepted by run_commands.",
            "inputSchema": ["type": "object", "properties": [:] as [String: Any]],
        ],
        [
            "name": "list_pages",
            "description": "Pages in the open document.",
            "inputSchema": ["type": "object", "properties": [:] as [String: Any]],
        ],
        [
            "name": "select_page",
            "description": "Switch the open document to a page by index.",
            "inputSchema": ["type": "object", "properties": ["index": ["type": "integer"]],
                            "required": ["index"]],
        ],
        [
            "name": "export_svg",
            "description": "The current page as SVG.",
            "inputSchema": ["type": "object", "properties": [:] as [String: Any]],
        ],
    ]

    // MARK: - HTTP

    private func rpc(_ id: Any, _ result: [String: Any]) -> Data {
        let payload: [String: Any] = ["jsonrpc": "2.0", "id": id, "result": result]
        let body = (try? JSONSerialization.data(withJSONObject: payload)) ?? Data()
        return http(String(decoding: body, as: UTF8.self))
    }

    private func http(_ body: String) -> Data {
        let bytes = Array(body.utf8)
        let head = """
        HTTP/1.1 200 OK\r
        Content-Type: application/json\r
        Content-Length: \(bytes.count)\r
        Connection: close\r
        \r

        """
        return Data(head.utf8) + Data(bytes)
    }
}
