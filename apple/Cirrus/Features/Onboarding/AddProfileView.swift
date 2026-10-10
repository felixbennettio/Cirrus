import AuthenticationServices
import CirrusKit
import SwiftUI

/// Adds (or edits) a credential: Cloudflare sign-in, an API token or the
/// Global API Key. Credentials are verified before they are saved.
struct AddProfileView: View {
    var firstRun = false
    var editing: Profile?

    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @Environment(\.openURL) private var openURL
    @Environment(\.webAuthenticationSession) private var webAuth

    @State private var kind = AuthKind.apiToken
    @State private var name = ""
    @State private var token = ""
    @State private var email = ""
    @State private var apiKey = ""
    @State private var accountId = ""
    @State private var originCa = ""
    @State private var clientId = ""
    @State private var scopes = ""
    @State private var reveal = false
    @State private var busy = false
    @State private var signingIn = false
    @State private var error: String?
    @State private var loaded = false

    private var editingOAuth: Bool { editing?.kind == .oauth }
    private var needsPro: Bool { editing == nil && !firstRun && !model.pro.hasPro && !model.profiles.isEmpty }

    var body: some View {
        Group {
            if needsPro {
                PaywallView(feature: .credentials)
            } else {
                form
            }
        }
        .navigationTitle(firstRun ? "" : editing == nil ? L("Add credential", "添加凭据") : L("Edit credential", "编辑凭据"))
        .inlineTitle()
        .toolbar {
            if !firstRun {
                ToolbarItem(placement: .cancellationAction) { Button(L("Cancel", "取消")) { dismiss() } }
            }
        }
        .onAppear(perform: load)
    }

    private var form: some View {
        Form {
            if firstRun {
                Section {
                    VStack(spacing: 10) {
                        Image("Logo").resizable().frame(width: 96, height: 96).clipShape(.rect(cornerRadius: 22))
                        Text("Cirrus").font(.largeTitle.bold())
                        Text(L("A fast, native client for the Cloudflare API.", "快速、原生的 Cloudflare API 客户端。"))
                            .foregroundStyle(.secondary)
                            .multilineTextAlignment(.center)
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 12)
                }
                .listRowBackground(Color.clear)
            }

            if editing == nil || editingOAuth { oauthSection }

            if !editingOAuth {
                Section {
                    Picker(L("Type", "类型"), selection: $kind) {
                        Text("API Token").tag(AuthKind.apiToken)
                        Text("Global API Key").tag(AuthKind.globalKey)
                    }
                    .pickerStyle(.segmented)
                    .disabled(editing != nil)
                    if kind == .apiToken {
                        secretField("API Token", text: $token)
                    } else {
                        TextField(L("Account e-mail", "账户邮箱"), text: $email).plainInput().emailInput()
                        secretField("Global API Key", text: $apiKey)
                    }
                } header: {
                    Text(editing == nil ? L("Or use an API token / Global API Key", "或使用 API Token / Global API Key") : L("Credential", "凭据"))
                } footer: {
                    Text(
                        kind == .apiToken
                            ? L(
                                "Create a token with the permissions you need under My Profile → API Tokens (or an account-owned token under Manage Account → API Tokens).",
                                "在「我的个人资料 → API 令牌」中创建带所需权限的 Token（也可以在「管理账户 → API 令牌」中创建账户 Token）。")
                            : L(
                                "The legacy Global API Key has full access to everything your user can do. Prefer scoped API tokens when possible.",
                                "Global API Key 拥有该用户的全部权限，请尽量使用有范围限制的 API Token。"))
                }
            }

            Section {
                TextField(L("Name (optional)", "名称（可选）"), text: $name, prompt: Text(L("e.g. Personal, Company", "例如：个人、公司")))
                DisclosureGroup(L("Advanced", "高级选项")) {
                    if kind == .apiToken && !editingOAuth {
                        TextField(L("Account ID (account-owned tokens)", "账户 ID（账户 Token 需要）"), text: $accountId)
                            .plainInput()
                            .font(.body.monospaced())
                    }
                    SecureField(L("Origin CA Key (optional)", "Origin CA Key（可选）"), text: $originCa)
                }
            } footer: {
                Text(L("The Origin CA key is used only for Origin CA certificate endpoints.", "Origin CA Key 仅用于 Origin CA 证书相关接口。"))
            }

            if let error {
                Section { Label(error, systemImage: "exclamationmark.triangle.fill").foregroundStyle(.red) }
            }

            Section {
                Button {
                    Task { await submit() }
                } label: {
                    HStack {
                        if busy && !signingIn { ProgressView().controlSize(.small) }
                        Text(editingOAuth ? L("Save", "保存") : L("Verify & save", "验证并保存")).fontWeight(.semibold)
                    }
                    .frame(maxWidth: .infinity, minHeight: 30)
                }
                .buttonStyle(.glassProminent)
                .disabled(busy)
                .listRowBackground(Color.clear)
                .listRowInsets(EdgeInsets())
            } footer: {
                VStack(alignment: .leading, spacing: 10) {
                    if !editingOAuth {
                        Button(L("Create a token in the Cloudflare dashboard", "在 Cloudflare 面板中创建 Token"), systemImage: "arrow.up.right.square") {
                            openURL(URL(string: "https://dash.cloudflare.com/profile/api-tokens")!)
                        }
                        .font(.footnote)
                    }
                    Label(
                        L(
                            "Credentials are stored only on this device, in the system keychain. Cirrus talks directly to api.cloudflare.com — there is no intermediate server.",
                            "凭据只保存在本设备的系统钥匙串中。Cirrus 直接连接 api.cloudflare.com，没有任何中间服务器。"),
                        systemImage: "lock")
                }
                .padding(.top, 8)
            }
        }
        .formStyle(.grouped)
        .frame(minWidth: 460, minHeight: 560)
    }

    private var oauthSection: some View {
        Section {
            Button {
                Task { await signIn() }
            } label: {
                HStack {
                    if signingIn { ProgressView().controlSize(.small) } else { Image(systemName: "person.badge.key") }
                    Text(editingOAuth ? L("Sign in again", "重新登录") : L("Sign in with Cloudflare", "使用 Cloudflare 账户登录"))
                        .fontWeight(.semibold)
                }
                .frame(maxWidth: .infinity, minHeight: 34)
            }
            .buttonStyle(.glassProminent)
            .tint(.orange)
            .disabled(busy)
            .listRowBackground(Color.clear)
            .listRowInsets(EdgeInsets())

            DisclosureGroup(L("Use your own OAuth client", "使用自己的 OAuth 客户端")) {
                TextField("Client ID", text: $clientId).plainInput().font(.body.monospaced())
                TextField(L("Scopes (space separated)", "权限范围（空格分隔）"), text: $scopes, axis: .vertical)
                    .plainInput()
                    .font(.callout.monospaced())
                Text(
                    L(
                        "Create a client under Manage Account → OAuth clients (PKCE, no client secret) and register the redirect URL \(OAuthRedirect.web.absoluteString)",
                        "在「管理账户 → OAuth 客户端」中创建（PKCE，无需客户端密钥），并登记回调地址 \(OAuthRedirect.web.absoluteString)")
                )
                .font(.caption).foregroundStyle(.secondary)
            }
            if editingOAuth, let p = editing { GrantedScopes(profile: p) }
        } footer: {
            Text(
                L(
                    "Opens Cloudflare: pick the account and approve the permissions. No token to copy.",
                    "将打开 Cloudflare 授权页面，选择账户并同意授权即可，无需复制 Token。"))
        }
    }

    private func secretField(_ title: String, text: Binding<String>) -> some View {
        HStack {
            Group {
                if reveal {
                    TextField(title, text: text)
                } else {
                    SecureField(title, text: text)
                }
            }
            .plainInput()
            .font(.body.monospaced())
            Button {
                reveal.toggle()
            } label: {
                Image(systemName: reveal ? "eye.slash" : "eye")
            }
            .buttonStyle(.borderless)
        }
    }

    private func load() {
        guard !loaded, let p = editing else { return }
        loaded = true
        kind = p.kind == .oauth ? .apiToken : p.kind
        name = p.name
        token = p.token ?? ""
        email = p.email ?? ""
        apiKey = p.apiKey ?? ""
        accountId = p.accountId ?? ""
        originCa = p.originCaKey ?? ""
        if p.kind == .oauth {
            clientId = p.oauthClientId == OAuthConfig.defaultClientId ? "" : p.oauthClientId ?? ""
            scopes = p.oauthClientId == OAuthConfig.defaultClientId ? "" : p.oauthScopes.joined(separator: " ")
        }
    }

    private func clean(_ s: String) -> String? {
        let t = s.trimmingCharacters(in: .whitespacesAndNewlines)
        return t.isEmpty ? nil : t
    }

    // MARK: OAuth

    private func signIn() async {
        error = nil
        busy = true
        signingIn = true
        defer {
            busy = false
            signingIn = false
        }
        var config: OAuthConfig
        if let id = clean(clientId) {
            config = OAuthConfig(clientId: id, scopes: OAuthConfig.parseScopes(scopes))
        } else {
            // The built-in client: request the scopes it is configured with on
            // Cloudflare right now (as the Cirrus website reports them).
            config = await OAuthScopeResolver(store: DefaultsStore()).resolve(.builtIn)
        }
        let previous = editingOAuth ? editing : nil
        do {
            let tokens = try await signInWithCloudflare(config)
            var profile = Profile(
                id: previous?.id ?? Profile.newID(), name: clean(name) ?? previous?.name ?? "Cloudflare", kind: .oauth,
                originCaKey: clean(originCa), oauthClientId: config.clientId, oauthScopes: config.scopes,
                createdAt: previous?.createdAt ?? Date())
            // Re-authorizing replaces the old grant; revoke it once the new one works.
            let oldGrant = previous == nil ? nil : await model.keychain.readTokens(profileId: previous!.id)
            let session = try await model.sessions.adopt(profile, tokens: tokens)
            let result = await verifyProfile(profile, client: CFClient(profile: profile, tokens: session))
            guard result.ok else {
                if previous == nil { await model.sessions.remove(profile) }
                error = result.error ?? L("Verification failed", "验证失败")
                return
            }
            if let old = oldGrant?.refreshToken, old != tokens.refreshToken {
                let api = OAuthAPI()
                let client = previous?.oauthClientId ?? config.clientId
                Task.detached { await api.revoke(clientId: client, token: old) }
            }
            if let e = result.email { profile.email = e }
            save(profile, result)
        } catch let e as OAuthError {
            if e.code != "cancelled" { error = oauthMessage(e) }
        } catch {
            self.error = describe(error)
        }
    }

    private func signInWithCloudflare(_ config: OAuthConfig) async throws -> OAuthTokens {
        let api = OAuthAPI()
        let pkce = PKCE.generate()
        let state = randomURLSafe(32)
        let url = api.authorizeURL(config, redirect: OAuthRedirect.web, state: state, pkce: pkce)
        let callback: URL
        do {
            callback = try await webAuth.authenticate(
                using: url, callback: .customScheme(OAuthRedirect.appScheme), additionalHeaderFields: [:])
        } catch let e as ASWebAuthenticationSessionError where e.code == .canceledLogin {
            throw OAuthError("cancelled")
        }
        let code = try authorizationCode(from: callback, state: state)
        return try await api.exchangeCode(config, code: code, redirect: OAuthRedirect.web, pkce: pkce)
    }

    private func oauthMessage(_ e: OAuthError) -> String {
        switch e.code {
        case "access_denied": return L("Authorization was declined.", "授权已被拒绝。")
        case "invalid_scope":
            return L("The OAuth client does not allow the requested scopes. (\(e))", "OAuth 客户端不允许请求的权限范围。（\(e)）")
        default: return L("Sign-in failed: \(e)", "登录失败：\(e)")
        }
    }

    // MARK: Tokens and keys

    private func submit() async {
        error = nil
        if let base = editing, base.kind == .oauth {
            // Only the name and Origin CA key are editable; the grant stays as is.
            var p = base
            p.name = clean(name) ?? base.name
            p.originCaKey = clean(originCa)
            do {
                try model.upsert(p)
                dismiss()
            } catch {
                self.error = describe(error)
            }
            return
        }
        let profile = Profile(
            id: editing?.id ?? Profile.newID(),
            name: clean(name) ?? (kind == .globalKey ? clean(email) ?? "Cloudflare" : "Cloudflare"), kind: kind,
            token: kind == .apiToken ? clean(token) : nil, email: kind == .globalKey ? clean(email) : nil,
            apiKey: kind == .globalKey ? clean(apiKey) : nil, originCaKey: clean(originCa),
            accountId: kind == .apiToken ? clean(accountId) : nil, createdAt: editing?.createdAt ?? Date())
        if kind == .apiToken && profile.token == nil {
            error = L("Enter an API token.", "请输入 API Token。")
            return
        }
        if kind == .globalKey && (profile.email == nil || profile.apiKey == nil) {
            error = L("Enter your e-mail and Global API Key.", "请输入邮箱和 Global API Key。")
            return
        }
        busy = true
        defer { busy = false }
        let result = await verifyProfile(profile)
        guard result.ok else {
            error = result.error ?? L("Verification failed", "验证失败")
            return
        }
        save(profile, result)
    }

    /// Names [profile] after its first account (unless named), saves it and leaves.
    private func save(_ profile: Profile, _ result: VerifyResult) {
        var p = profile
        if clean(name) == nil, editing == nil, let first = result.accounts.first?["name"].string { p.name = first }
        do {
            try model.upsert(p)
        } catch {
            self.error = describe(error)
            return
        }
        QueryCache.shared.clear()
        model.feedback.show(
            L("Verified. \(result.accounts.count) account(s) available.", "验证成功，可访问 \(result.accounts.count) 个账户。"))
        if !firstRun { dismiss() }
    }
}

/// The scopes granted at sign-in, and requested ones that were not.
private struct GrantedScopes: View {
    let profile: Profile
    @Environment(AppModel.self) private var model
    @State private var granted: [String]?

    var body: some View {
        DisclosureGroup {
            if let granted {
                if granted.isEmpty {
                    Text(L("This sign-in did not record its permissions. Sign in again to see them.", "本次登录没有记录授权范围，重新登录后即可查看。"))
                        .font(.caption).foregroundStyle(.secondary)
                } else {
                    Text(granted.joined(separator: "  ")).font(.caption.monospaced()).textSelection(.enabled)
                    let missing = profile.oauthScopes.filter { $0 != OAuthConfig.offlineScope && !granted.contains($0) }
                    if !missing.isEmpty {
                        Text(L("Requested but not granted", "已请求但未授予")).font(.caption.weight(.semibold))
                        Text(missing.joined(separator: "  ")).font(.caption.monospaced()).strikethrough().foregroundStyle(.secondary)
                    }
                }
            }
        } label: {
            LabeledContent(L("Granted permissions", "已授予的权限"), value: granted.map { L("\($0.count) scopes", "\($0.count) 项") } ?? "…")
        }
        .task {
            let tokens = await model.keychain.readTokens(profileId: profile.id)
            granted = (tokens?.scopes ?? []).filter { $0 != OAuthConfig.offlineScope }
        }
    }
}

/// UserDefaults as a `KeyValueStore`.
struct DefaultsStore: KeyValueStore {
    func string(forKey key: String) -> String? { UserDefaults.standard.string(forKey: key) }
    func set(_ value: String?, forKey key: String) { UserDefaults.standard.set(value, forKey: key) }
}

extension View {
    func emailInput() -> some View {
        #if os(iOS)
            return keyboardType(.emailAddress).textContentType(.emailAddress)
        #else
            return self
        #endif
    }
}
