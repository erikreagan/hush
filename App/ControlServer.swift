import Foundation
import Network

/// Local WebSocket control surface (SPEC §8). Bound to 127.0.0.1 only; JSON text messages.
/// Everything runs on the main queue.
@MainActor
final class ControlServer {
    private var listener: NWListener?
    private var clients: [ObjectIdentifier: (connection: NWConnection, topics: Set<String>)] = [:]
    /// Handles a command message; returns an error string or nil.
    var onCommand: (([String: Any]) -> String?)?
    /// Latest message per topic, sent immediately on subscribe.
    private var latest: [String: String] = [:]
    private(set) var startError: String?
    var clientCount: Int { clients.count }

    func start(port: UInt16) {
        let webSocket = NWProtocolWebSocket.Options()
        webSocket.autoReplyPing = true
        let parameters = NWParameters.tcp
        parameters.defaultProtocolStack.applicationProtocols.insert(webSocket, at: 0)
        parameters.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: NWEndpoint.Port(rawValue: port) ?? 47823)
        parameters.allowLocalEndpointReuse = true
        do {
            let listener = try NWListener(using: parameters)
            listener.newConnectionHandler = { connection in MainActor.assumeIsolated { self.accept(connection) } }
            listener.stateUpdateHandler = { state in
                if case .failed(let error) = state { MainActor.assumeIsolated { self.startError = "\(error)" } }
            }
            listener.start(queue: .main)
            self.listener = listener
        } catch {
            startError = "\(error)"
        }
    }

    /// Sends `json` to every client subscribed to `topic`. `onlyIfChanged` suppresses repeats.
    func publish(topic: String, _ payload: [String: Any], onlyIfChanged: Bool = false) {
        var payload = payload
        payload["type"] = topic
        guard let json = Self.encode(payload) else { return }
        if onlyIfChanged, latest[topic] == json { return }
        latest[topic] = json
        for client in clients.values where client.topics.contains(topic) { send(json, to: client.connection) }
    }

    private func accept(_ connection: NWConnection) {
        let id = ObjectIdentifier(connection)
        clients[id] = (connection, [])
        connection.stateUpdateHandler = { state in
            switch state {
            case .failed, .cancelled: MainActor.assumeIsolated { self.clients[id] = nil }
            default: break
            }
        }
        connection.start(queue: .main)
        receive(on: connection)
    }

    private func receive(on connection: NWConnection) {
        connection.receiveMessage { data, _, _, error in
            MainActor.assumeIsolated {
                guard error == nil, let data else { connection.cancel(); return }
                if !data.isEmpty { self.handle(data, from: connection) }
                self.receive(on: connection)
            }
        }
    }

    private func handle(_ data: Data, from connection: NWConnection) {
        guard let message = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return sendError("Message is not a JSON object", to: connection)
        }
        if message["type"] as? String == "subscribe" {
            let topics = Set(message["topics"] as? [String] ?? [])
            clients[ObjectIdentifier(connection)]?.topics.formUnion(topics)
            if topics.contains("state"), let state = latest["state"] { send(state, to: connection) }
        } else if let problem = onCommand?(message) {
            sendError(problem, to: connection)
        }
    }

    private func sendError(_ message: String, to connection: NWConnection) {
        if let json = Self.encode(["type": "error", "message": message]) { send(json, to: connection) }
    }

    private func send(_ json: String, to connection: NWConnection) {
        let metadata = NWProtocolWebSocket.Metadata(opcode: .text)
        let context = NWConnection.ContentContext(identifier: "text", metadata: [metadata])
        connection.send(content: Data(json.utf8), contentContext: context, completion: .idempotent)
    }

    private static func encode(_ object: [String: Any]) -> String? {
        (try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])).flatMap { String(data: $0, encoding: .utf8) }
    }
}
