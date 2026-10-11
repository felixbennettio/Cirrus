import CirrusKit
import SwiftUI

/// Results of recent loads, so a screen renders at once when it is opened
/// again and refreshes in the background.
@MainActor
final class QueryCache {
    static let shared = QueryCache()
    private var values: [String: Any] = [:]

    func value<T>(_ key: String) -> T? { values[key] as? T }
    func set(_ key: String, _ value: Any) { values[key] = value }
    func clear() { values.removeAll() }
}

/// The state of one API load.
@MainActor @Observable
final class Query<T> {
    var value: T?
    var error: Error?
    var isLoading = false
    @ObservationIgnored private var key: String?
    @ObservationIgnored private var generation = 0

    /// Loads [fetch] for [key]. A cached value shows right away; without
    /// [force] a value already loaded for the same key is kept.
    func load(key: String, client: CFClient?, force: Bool = false, _ fetch: (CFClient) async throws -> T) async {
        guard let client else { return }
        let full = client.profile.id + "|" + key
        if full != self.key {
            self.key = full
            value = QueryCache.shared.value(full)
            error = nil
        } else if !force, value != nil, !isLoading {
            return
        }
        generation += 1
        let gen = generation
        isLoading = true
        defer { if gen == generation { isLoading = false } }
        do {
            let v = try await fetch(client)
            guard gen == generation else { return }
            value = v
            error = nil
            QueryCache.shared.set(full, v)
        } catch {
            guard gen == generation, !Task.isCancelled else { return }
            if (error as? URLError)?.code == .cancelled || error is CancellationError { return }
            self.error = error
        }
    }

    /// Replaces the value (after a write that returned the new state).
    func set(_ v: T) {
        value = v
        if let key { QueryCache.shared.set(key, v) }
    }
}

/// Lets a screen reload or patch what it shows.
@MainActor
struct QueryHandle<T> {
    let reload: () async -> Void
    let set: (T) -> Void
    let isLoading: Bool
}

/// Loads data for a screen: spinner, error with retry, then [content].
struct QueryView<T, Content: View>: View {
    @Environment(AppModel.self) private var model
    let key: String
    let fetch: (CFClient) async throws -> T
    let content: (T, QueryHandle<T>) -> Content
    @State private var query = Query<T>()

    init(
        _ key: String, fetch: @escaping (CFClient) async throws -> T,
        @ViewBuilder content: @escaping (T, QueryHandle<T>) -> Content
    ) {
        self.key = key
        self.fetch = fetch
        self.content = content
    }

    private var handle: QueryHandle<T> {
        let q = query
        let key = key
        let fetch = fetch
        let model = model
        return QueryHandle(
            reload: { await q.load(key: key, client: model.client, force: true, fetch) },
            set: { q.set($0) },
            isLoading: q.isLoading)
    }

    var body: some View {
        Group {
            if let v = query.value {
                content(v, handle)
            } else if let e = query.error {
                ErrorState(error: e) { Task { await handle.reload() } }
            } else {
                ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .task(id: key + "|" + (model.client?.profile.id ?? "")) {
            await query.load(key: key, client: model.client, fetch)
        }
    }
}

/// A full-screen error with a retry button. Features the plan does not
/// include and missing token permissions get their own wording.
struct ErrorState: View {
    let error: Error
    var retry: (() -> Void)?

    var body: some View {
        let api = error as? CFAPIError
        if api?.isPlanRestricted == true {
            ContentUnavailableView {
                Label(L("Not available on this plan", "当前套餐不可用"), systemImage: "lock")
            } description: {
                detail(
                    L(
                        "Cloudflare doesn't include this feature in the domain's or account's current plan.",
                        "域名或账户的当前 Cloudflare 套餐不包含此功能。"))
            }
        } else if api?.isAuthError == true || api?.isForbidden == true {
            ContentUnavailableView {
                Label(L("No access", "没有权限"), systemImage: "key.slash")
            } description: {
                detail(
                    L(
                        "The current credential can't access this. Add the permission to the API token, or sign in with Cloudflare.",
                        "当前凭据无权访问此内容。请给 API Token 添加相应权限，或改用 Cloudflare 登录。"))
            } actions: {
                if let retry {
                    Button(L("Try again", "重试"), action: retry).buttonStyle(.glass)
                }
            }
        } else {
            ContentUnavailableView {
                Label(L("Something went wrong", "出错了"), systemImage: "exclamationmark.triangle")
            } description: {
                Text(describe(error)).textSelection(.enabled)
            } actions: {
                if let retry {
                    Button(L("Try again", "重试"), action: retry).buttonStyle(.glass)
                }
            }
        }
    }

    private func detail(_ explanation: String) -> some View {
        VStack(spacing: 8) {
            Text(explanation)
            Text(describe(error)).font(.caption).textSelection(.enabled)
        }
    }
}
