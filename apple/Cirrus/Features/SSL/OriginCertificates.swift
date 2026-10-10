import CirrusKit
import CryptoKit
import SwiftUI

/// Origin CA certificates. New ones get an ECDSA key generated on this
/// device; the private key never leaves it.
struct OriginCertificates: View {
    let zone: ZoneRef
    @Environment(AppModel.self) private var model
    @State private var creating = false
    @State private var revoking: JSON?
    @State private var export: ExportItem?

    var body: some View {
        QueryView(
            "origin-certs:" + zone.id,
            fetch: { c in try await c.list("/certificates", query: ["zone_id": zone.id], perPage: 50) }
        ) { certs, h in
            Form {
                Section {
                    if certs.isEmpty { Text(L("No origin certificates", "没有源站证书")).foregroundStyle(.secondary) }
                    ForEach(certs, id: \.self) { cert in
                        HStack(spacing: 12) {
                            Image(systemName: "checkmark.seal").foregroundStyle(.tint)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(cert["hostnames"].strings.joined(separator: ", ")).lineLimit(2)
                                Text(
                                    "\(cert["request_type"].string ?? "") · \(L("expires", "到期")) \(Format.date(cert["expires_on"], withTime: false))"
                                )
                                .font(.caption).foregroundStyle(.secondary)
                            }
                            Spacer()
                            Menu {
                                Button(L("Save certificate", "保存证书"), systemImage: "square.and.arrow.down") {
                                    export = ExportItem(
                                        file: TextFile(cert["certificate"].string ?? ""),
                                        name: "origin-\(cert["id"].text ?? "cert").pem")
                                }
                                Button(L("Copy certificate", "复制证书"), systemImage: "doc.on.doc") {
                                    Clipboard.copy(cert["certificate"].string ?? "")
                                }
                                Divider()
                                Button(L("Revoke", "吊销"), systemImage: "xmark.seal", role: .destructive) { revoking = cert }
                            } label: {
                                Image(systemName: "ellipsis.circle").foregroundStyle(.secondary)
                            }
                            .buttonStyle(.borderless)
                            .menuIndicator(.hidden)
                            .fixedSize()
                        }
                    }
                } header: {
                    HStack {
                        Text(L("Origin CA certificates", "Origin CA 证书"))
                        Spacer()
                        Button(L("Create", "创建"), systemImage: "plus") { creating = true }.font(.caption)
                    }
                } footer: {
                    Text(
                        L(
                            "Free certificates trusted by Cloudflare for encrypting traffic to your origin (Full strict). Requests use your Origin CA key when the credential has one.",
                            "受 Cloudflare 信任的免费证书，用于加密回源流量（完全严格模式）。凭据设置了 Origin CA Key 时会使用它。"))
                }
            }
            .formStyle(.grouped)
            .refreshable { await h.reload() }
            .sheet(isPresented: $creating) { CreateOriginCertSheet(zone: zone) { await h.reload() } }
            .confirmationDialog(
                L("Revoke certificate?", "吊销证书？"),
                isPresented: Binding(get: { revoking != nil }, set: { if !$0 { revoking = nil } }),
                titleVisibility: .visible, presenting: revoking
            ) { cert in
                Button(L("Revoke", "吊销"), role: .destructive) {
                    Task {
                        await model.run(L("Revoked", "已吊销")) {
                            try await model.client?.send("DELETE", "/certificates/\(cert["id"].text ?? "")", originCA: true)
                        }
                        await h.reload()
                    }
                }
            } message: { _ in
                Text(L("Origins using it will stop working with Full (strict).", "使用该证书的源站在完全（严格）模式下将无法工作。"))
            }
        }
        .exporter($export)
    }
}

private struct CreateOriginCertSheet: View {
    let zone: ZoneRef
    let done: () async -> Void
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State private var hosts: String
    @State private var validity = 5475
    @State private var ownCSR = false
    @State private var csr = ""
    @State private var busy = false
    @State private var result: (certificate: String, privateKey: String?)?
    @State private var export: ExportItem?

    init(zone: ZoneRef, done: @escaping () async -> Void) {
        self.zone = zone
        self.done = done
        _hosts = State(initialValue: "\(zone.name)\n*.\(zone.name)")
    }

    var body: some View {
        NavigationStack {
            Form {
                if let result {
                    Section {
                        Button(L("Save certificate", "保存证书"), systemImage: "square.and.arrow.down") {
                            export = ExportItem(file: TextFile(result.certificate), name: "\(zone.name).origin.pem")
                        }
                        Button(L("Copy certificate", "复制证书"), systemImage: "doc.on.doc") { Clipboard.copy(result.certificate) }
                    } header: {
                        Text(L("Certificate", "证书"))
                    }
                    if let key = result.privateKey {
                        Section {
                            Button(L("Save private key", "保存私钥"), systemImage: "key") {
                                export = ExportItem(file: TextFile(key), name: "\(zone.name).origin.key")
                            }
                            Button(L("Copy private key", "复制私钥"), systemImage: "doc.on.doc") { Clipboard.copy(key) }
                        } header: {
                            Text(L("Private key", "私钥"))
                        } footer: {
                            Text(
                                L(
                                    "Save the private key now — it was generated on this device and is not stored anywhere else.",
                                    "请立即保存私钥——它是在本设备上生成的，不会保存在其他任何地方。"))
                        }
                    }
                } else {
                    Section(L("Hostnames (one per line)", "主机名（每行一个）")) {
                        TextField("", text: $hosts, axis: .vertical).plainInput().lineLimit(2...6)
                    }
                    Section {
                        Picker(L("Validity", "有效期"), selection: $validity) {
                            Text(L("7 days", "7 天")).tag(7)
                            Text(L("30 days", "30 天")).tag(30)
                            Text(L("90 days", "90 天")).tag(90)
                            Text(L("1 year", "1 年")).tag(365)
                            Text(L("2 years", "2 年")).tag(730)
                            Text(L("3 years", "3 年")).tag(1095)
                            Text(L("15 years", "15 年")).tag(5475)
                        }
                        Toggle(isOn: $ownCSR) {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(L("Use my own CSR", "使用我自己的 CSR"))
                                Text(L("Otherwise an ECDSA key is generated on this device.", "否则将在本设备上生成 ECDSA 私钥。"))
                                    .font(.caption).foregroundStyle(.secondary)
                            }
                        }
                        if ownCSR {
                            TextField("CSR (PEM)", text: $csr, axis: .vertical)
                                .plainInput()
                                .font(.caption.monospaced())
                                .lineLimit(4...12)
                        }
                    }
                }
            }
            .formStyle(.grouped)
            .navigationTitle(L("Create Origin CA certificate", "创建 Origin CA 证书"))
            .inlineTitle()
            .toolbar {
                if result == nil {
                    ToolbarItem(placement: .cancellationAction) { Button(L("Cancel", "取消")) { dismiss() } }
                    ToolbarItem(placement: .confirmationAction) {
                        Button(L("Create", "创建")) { Task { await create() } }.disabled(busy)
                    }
                } else {
                    ToolbarItem(placement: .confirmationAction) { Button(L("Done", "完成")) { dismiss() } }
                }
            }
            .exporter($export)
        }
        .frame(minWidth: 520, minHeight: 460)
        .interactiveDismissDisabled(result?.privateKey != nil)
    }

    private func create() async {
        let names = hosts.split(whereSeparator: \.isNewline).map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        guard !names.isEmpty else { return }
        busy = true
        defer { busy = false }
        var privateKey: String?
        let request: String
        if ownCSR {
            request = csr.trimmingCharacters(in: .whitespacesAndNewlines)
        } else {
            let key = P256.Signing.PrivateKey()
            guard
                let pem = try? CSR.make(hostnames: names, publicKey: key.publicKey.derRepresentation, sign: { info in
                    try key.signature(for: info).derRepresentation
                })
            else { return }
            request = pem
            privateKey = key.pemRepresentation
        }
        let body: JSON = [
            "hostnames": .array(names.map(JSON.string)), "requested_validity": .int(validity),
            "request_type": "origin-ecc", "csr": .string(request),
        ]
        let r = await model.run { try await model.client?.send("POST", "/certificates", body: .json(body), originCA: true) }
        guard let response = r, let res = response else { return }
        result = (res.result["certificate"].string ?? "", privateKey)
        await done()
    }
}
