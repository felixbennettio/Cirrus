import CirrusKit
import SwiftUI

struct SettingsView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.openURL) private var openURL
    @State private var adding = false
    @State private var editing: Profile?
    @State private var removing: Profile?
    @State private var paywall = false

    var body: some View {
        Form {
            if model.pro.enforced { proSection }
            credentials
            appearance
            security
            Section(L("Data", "数据")) {
                Button(L("Clear cached data", "清除缓存数据"), systemImage: "trash") {
                    model.clearCaches()
                    Task { await model.refresh() }
                    model.feedback.show(L("Cache cleared", "缓存已清除"))
                }
            }
            about
        }
        .formStyle(.grouped)
        .navigationTitle(L("Settings", "设置"))
        .sheet(isPresented: $adding) { NavigationStack { AddProfileView() } }
        .sheet(item: $editing) { p in NavigationStack { AddProfileView(editing: p) } }
        .sheet(isPresented: $paywall) { PaywallSheet() }
        .confirmationDialog(
            L("Remove credential?", "移除凭据？"),
            isPresented: Binding(get: { removing != nil }, set: { if !$0 { removing = nil } }),
            titleVisibility: .visible, presenting: removing
        ) { p in
            Button(L("Remove", "移除"), role: .destructive) { Task { await model.remove(p) } }
        } message: { p in
            Text(
                p.kind == .oauth
                    ? L("\(p.name) will be signed out and its authorization revoked.", "将退出 \(p.name) 并撤销其授权。")
                    : L("\(p.name) will be removed from this device.", "将从本设备移除 \(p.name)。"))
        }
    }

    private var proSection: some View {
        let pro = model.pro
        return Section {
            HStack {
                Image(systemName: pro.unlocked ? "checkmark.seal.fill" : "sparkles").foregroundStyle(.tint).font(.title2)
                VStack(alignment: .leading) {
                    Text(pro.unlocked ? L("Cirrus Pro (lifetime)", "Cirrus Pro（终身）") : "Cirrus Pro").fontWeight(.semibold)
                    Text(
                        pro.unlocked
                            ? L("Unlocked on this device. Thank you!", "已在本设备解锁，感谢支持！")
                            : L("A one-time purchase that unlocks every feature.", "一次性购买，解锁全部功能。")
                    )
                    .font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                if !pro.unlocked {
                    Button(L("Unlock", "解锁")) { paywall = true }.buttonStyle(.glassProminent)
                }
            }
            if !pro.unlocked {
                Button(L("Restore purchase", "恢复购买")) { Task { await pro.restore() } }.disabled(pro.busy)
            }
            if pro.testFlightUnlock && !pro.unlocked {
                Text(
                    L(
                        "Unlocked for TestFlight testing while the App Store can't sell Cirrus Pro yet.",
                        "App Store 暂时还不能购买 Cirrus Pro，TestFlight 测试期间已临时解锁。")
                )
                .font(.caption).foregroundStyle(.secondary)
            } else if let e = pro.error {
                Text(e).font(.caption).foregroundStyle(.red)
            }
        }
    }

    private var credentials: some View {
        Section {
            ForEach(model.profiles) { p in
                HStack {
                    Image(systemName: p.id == model.activeProfile?.id ? "checkmark.circle.fill" : "person.crop.circle")
                        .foregroundStyle(.tint)
                    VStack(alignment: .leading) {
                        Text(p.name)
                        Text(
                            p.kind == .globalKey
                                ? "Global API Key · \(p.email ?? "") · \(p.secretHint)" : "\(p.kindLabel) · \(p.secretHint)"
                        )
                        .font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer()
                    Menu {
                        Button(L("Use", "使用"), systemImage: "checkmark") { model.setActiveProfile(p.id) }
                        Button(L("Edit", "编辑"), systemImage: "pencil") { editing = p }
                        Divider()
                        Button(L("Remove", "移除"), systemImage: "trash", role: .destructive) { removing = p }
                    } label: {
                        Image(systemName: "ellipsis.circle").foregroundStyle(.secondary)
                    }
                    .buttonStyle(.borderless)
                    .menuIndicator(.hidden)
                    .fixedSize()
                }
                .contentShape(.rect)
                .onTapGesture { model.setActiveProfile(p.id) }
            }
            Button(L("Add credential", "添加凭据"), systemImage: "plus") {
                if model.pro.hasPro || model.profiles.isEmpty { adding = true } else { paywall = true }
            }
        } header: {
            Text(L("Credentials", "凭据"))
        } footer: {
            Text(L("Stored in the system keychain on this device.", "保存在本设备的系统钥匙串中。"))
        }
    }

    private var appearance: some View {
        Section(L("Appearance", "外观")) {
            Picker(L("Theme", "主题"), selection: Binding(get: { model.settings.themeMode }, set: { v in model.update { $0.themeMode = v } })) {
                Text(L("System", "跟随系统")).tag(ThemeMode.system)
                Text(L("Light", "浅色")).tag(ThemeMode.light)
                Text(L("Dark", "深色")).tag(ThemeMode.dark)
            }
            Picker(
                L("Language", "语言"),
                selection: Binding(get: { model.settings.localeCode ?? "system" }, set: { v in model.update { $0.localeCode = v == "system" ? nil : v } })
            ) {
                Text(L("System", "跟随系统")).tag("system")
                Text("English").tag("en")
                Text("简体中文").tag("zh")
            }
        }
    }

    private var security: some View {
        Section(L("Security", "安全")) {
            let available = Biometrics.available
            Toggle(isOn: Binding(get: { model.settings.appLock && available }, set: { v in
                Task {
                    if await Biometrics.authenticate(L("Confirm to change app lock", "确认以修改应用锁")) {
                        model.update { $0.appLock = v }
                    }
                }
            })) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(L("App lock", "应用锁"))
                    Text(
                        available
                            ? L("Require Face ID, Touch ID or the device passcode to open Cirrus.", "打开 Cirrus 时需要面容 ID、触控 ID 或设备密码。")
                            : L("Not available on this device.", "此设备不支持。")
                    )
                    .font(.caption).foregroundStyle(.secondary)
                }
            }
            .disabled(!available)
        }
    }

    private var about: some View {
        Section(L("About", "关于")) {
            HStack(spacing: 12) {
                Image("Logo").resizable().frame(width: 44, height: 44).clipShape(.rect(cornerRadius: 10))
                VStack(alignment: .leading) {
                    Text("Cirrus").fontWeight(.semibold)
                    Text(L("Version", "版本") + " \(AppInfo.version) (\(AppInfo.build))").font(.caption).foregroundStyle(.secondary)
                }
            }
            Text(
                L(
                    "Cirrus is an unofficial client and is not affiliated with, endorsed or sponsored by Cloudflare, Inc. \"Cloudflare\" is a trademark of Cloudflare, Inc.",
                    "Cirrus 是非官方客户端，与 Cloudflare, Inc. 没有任何关联，也未获其认可或赞助。“Cloudflare”是 Cloudflare, Inc. 的商标。")
            )
            .font(.caption).foregroundStyle(.secondary)
            Button(L("API documentation", "API 文档")) { openURL(URL(string: "https://developers.cloudflare.com/api/")!) }
            Button(L("Cloudflare status", "Cloudflare 服务状态")) { openURL(URL(string: "https://www.cloudflarestatus.com/")!) }
        }
    }
}
