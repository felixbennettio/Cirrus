import CirrusKit
import SwiftUI

/// A live `wrangler tail`-style session over a WebSocket.
@MainActor @Observable
final class TailSession {
    private(set) var events: [TailEvent] = []
    private(set) var live = false
    private(set) var connecting = false
    var error: String?
    @ObservationIgnored private var task: URLSessionWebSocketTask?
    @ObservationIgnored private var tailPath: String?
    @ObservationIgnored private var client: CFClient?

    func start(client: CFClient, accountId: String, script: String) async {
        guard !live, !connecting else { return }
        connecting = true
        error = nil
        defer { connecting = false }
        let path = Workers.scriptPath(accountId, script) + "/tails"
        do {
            let r = try await client.post(path)
            guard let s = r["url"].string, let url = URL(string: s), let id = r["id"].string else {
                throw SimpleError(L("The API returned no tail URL.", "API 没有返回实时日志地址。"))
            }
            self.client = client
            tailPath = path + "/" + id.pathEncoded
            var req = URLRequest(url: url)
            req.setValue("trace-v1", forHTTPHeaderField: "Sec-WebSocket-Protocol")
            req.setValue(CFClient.userAgent, forHTTPHeaderField: "User-Agent")
            let t = URLSession.shared.webSocketTask(with: req)
            task = t
            t.resume()
            try await t.send(.string(#"{"debug":true}"#))
            live = true
            Task { await receive(t) }
        } catch {
            self.error = describe(error)
            await stop()
        }
    }

    private func receive(_ t: URLSessionWebSocketTask) async {
        while live, task === t {
            do {
                let text: String
                switch try await t.receive() {
                case .string(let s): text = s
                case .data(let d): text = String(decoding: d, as: UTF8.self)
                @unknown default: continue
                }
                let json = (try? JSON.parse(text)) ?? ["raw": .string(text)]
                events.insert(TailEvent(json), at: 0)
                if events.count > 500 { events.removeLast(events.count - 500) }
            } catch {
                if live && task === t { self.error = describe(error) }
                live = false
            }
        }
    }

    func stop() async {
        live = false
        task?.cancel(with: .normalClosure, reason: nil)
        task = nil
        if let path = tailPath, let client {
            _ = try? await client.delete(path)
        }
        tailPath = nil
    }

    func clear() { events.removeAll() }
}

struct WorkerTail: View {
    let accountId: String
    let script: String
    @Environment(AppModel.self) private var model
    @State private var session = TailSession()
    @State private var filter = ""
    @State private var jsonItem: JSONItem?

    private var shown: [TailEvent] {
        let f = filter.trimmingCharacters(in: .whitespaces).lowercased()
        return f.isEmpty ? session.events : session.events.filter { $0.searchText.contains(f) }
    }

    var body: some View {
        VStack(spacing: 8) {
            HStack {
                TextField(L("Filter logs", "过滤日志"), text: $filter).plainInput().textFieldStyle(.roundedBorder)
                if session.live {
                    Button(L("Stop", "停止"), systemImage: "stop.fill") { Task { await session.stop() } }
                        .buttonStyle(.glass)
                } else {
                    Button {
                        guard let client = model.client else { return }
                        Task { await session.start(client: client, accountId: accountId, script: script) }
                    } label: {
                        if session.connecting {
                            ProgressView().controlSize(.small)
                        } else {
                            Label(L("Start", "开始"), systemImage: "play.fill")
                        }
                    }
                    .buttonStyle(.glassProminent)
                    .disabled(session.connecting)
                }
                Button(L("Clear", "清空"), systemImage: "trash") { session.clear() }.labelStyle(.iconOnly)
            }
            .padding(.horizontal)
            if session.live {
                Label(L("Streaming live events…", "正在接收实时事件…"), systemImage: "dot.radiowaves.left.and.right")
                    .font(.caption).foregroundStyle(.green)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal)
            }
            if let e = session.error {
                Text(e).font(.caption).foregroundStyle(.red).padding(.horizontal)
            }
            List(shown) { e in
                TailRow(event: e).contentShape(.rect).onTapGesture { jsonItem = JSONItem(title: e.title, json: e.raw) }
            }
            .overlay {
                if shown.isEmpty {
                    EmptyState(
                        title: session.live ? L("Waiting for requests…", "等待请求…") : L("Not streaming", "未开始"),
                        symbol: "waveform.path.ecg",
                        message: L("Send a request to your Worker to see logs here.", "向 Worker 发送请求即可在这里看到日志。"))
                }
            }
        }
        .padding(.top, 8)
        .onDisappear { Task { await session.stop() } }
        .sheet(item: $jsonItem) { JSONSheet(title: $0.title, json: $0.json) }
    }
}

private struct TailRow: View {
    let event: TailEvent

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 8) {
                StatusBadge(event.outcome, tone: event.outcome == "ok" ? .good : .bad)
                if let s = event.status { Text(String(s)).font(.callout.weight(.bold)) }
                Text(event.title).font(.caption.monospaced()).lineLimit(1)
                Spacer()
                if let at = event.at { Text(at, style: .time).font(.caption2).foregroundStyle(.secondary) }
            }
            ForEach(Array(event.logs.enumerated()), id: \.offset) { _, l in
                Text("[\(l.level)] \(l.message)")
                    .font(.caption.monospaced())
                    .foregroundStyle(l.level == "error" ? Color.red : l.level == "warn" ? Color.orange : Color.primary)
            }
            ForEach(event.exceptions, id: \.self) { ex in
                Text("⚠ " + ex).font(.caption.monospaced()).foregroundStyle(.red)
            }
        }
    }
}
