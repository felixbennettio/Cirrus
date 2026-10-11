import Foundation
import Testing
@testable import CirrusKit

@Suite struct WorkersTests {
    @Test func singleScriptContent() {
        let c = Workers.parseContent(Data("export default { fetch() {} }".utf8), contentType: "application/javascript", entrypoint: nil)
        #expect(c.mainModule == "worker.js")
        #expect(c.moduleSyntax)
        #expect(c.modules.first?.contentType == "application/javascript+module")
        let sw = Workers.parseContent(Data("addEventListener('fetch', e => {})".utf8), contentType: nil, entrypoint: "index.js")
        #expect(!sw.moduleSyntax)
        #expect(sw.mainModule == "index.js")
        #expect(sw.modules.first?.contentType == "application/javascript")
    }

    @Test func multipartContentRoundTrip() {
        let modules = [
            WorkerModule(name: "index.js", contentType: "application/javascript+module", data: Data("export default {}".utf8)),
            WorkerModule(name: "data.json", contentType: "application/json", data: Data("{\"a\":1}".utf8)),
            WorkerModule(name: "add.wasm", contentType: "application/wasm", data: Data([0, 97, 115, 109])),
        ]
        let form = Workers.scriptForm(metadata: ["main_module": "index.js"], modules: modules)
        // A download carries the same parts, without the metadata.
        var download = MultipartForm(boundary: form.boundary)
        for m in modules { download.addFile(m.name, filename: m.name, contentType: m.contentType, data: m.data) }
        let c = Workers.parseContent(download.body, contentType: download.contentType, entrypoint: "index.js")
        #expect(c.modules.map(\.name) == ["index.js", "data.json", "add.wasm"])
        #expect(c.moduleSyntax)
        #expect(c.main?.text == "export default {}")
        #expect(c.modules[2].data == Data([0, 97, 115, 109]))
        #expect(!c.modules[2].isText)
        #expect(c.modules[1].isText)
        let parts = parseMultipart(form.body, boundary: form.boundary)
        #expect(parts.first?.name == "metadata")
        #expect(parts.first?.contentType == "application/json")
        #expect((try? JSON.parse(parts[0].data))?["main_module"].string == "index.js")
        #expect(Workers.contentMetadata(c) == ["main_module": "index.js"])
    }

    @Test func bindingsKeepSecretsAsInherit() {
        let settings: JSON = [
            "bindings": [
                ["name": "API_URL", "type": "plain_text", "text": "https://a"],
                ["name": "TOKEN", "type": "secret_text"],
                ["name": "CACHE", "type": "kv_namespace", "namespace_id": "ns1"],
            ]
        ]
        let replaced = Workers.rebuildBindings(settings, replace: ["name": "API_URL", "type": "plain_text", "text": "https://b"])
        #expect(replaced.count == 3)
        #expect(replaced[0]["text"].string == "https://b")
        #expect(replaced[1] == ["name": "TOKEN", "type": "inherit"])
        let added = Workers.rebuildBindings(settings, replace: ["name": "NEW", "type": "plain_text", "text": "x"])
        #expect(added.last?["name"].string == "NEW")
        let removed = Workers.rebuildBindings(settings, remove: "CACHE")
        #expect(removed.map { $0["name"].string } == ["API_URL", "TOKEN"])
        #expect(Workers.bindingTarget(settings["bindings"][2]) == "ns1")
        #expect(Workers.bindingTarget(settings["bindings"][0]) == "https://a")
    }

    @Test func metricsMergeHours() throws {
        let data = try JSON.parse(
            """
            {"viewer":{"accounts":[{"workersInvocationsAdaptive":[
              {"sum":{"requests":10,"errors":1,"subrequests":2},"quantiles":{"cpuTimeP50":1.5,"cpuTimeP99":9},"dimensions":{"datetimeHour":"2026-10-10T02:00:00Z"}},
              {"sum":{"requests":5,"errors":0,"subrequests":1},"quantiles":{"cpuTimeP50":2,"cpuTimeP99":7},"dimensions":{"datetimeHour":"2026-10-10T02:00:00Z"}},
              {"sum":{"requests":1,"errors":0,"subrequests":0},"quantiles":{"cpuTimeP50":1,"cpuTimeP99":1},"dimensions":{"datetimeHour":"2026-10-10T01:00:00Z"}}
            ]}]}}
            """)
        let points = Workers.parseMetrics(data)
        #expect(points.count == 2)
        #expect(points[0].requests == 1)
        #expect(points[1].requests == 15 && points[1].errors == 1 && points[1].cpuP99 == 9 && points[1].cpuP50 == 2)
        let summary = Workers.parseSummary(
            try JSON.parse(#"{"viewer":{"accounts":[{"workersInvocationsAdaptive":[{"sum":{"requests":3,"errors":1},"dimensions":{"scriptName":"a"}},{"sum":{"requests":2,"errors":0},"dimensions":{"scriptName":"a"}}]}]}}"#))
        #expect(summary["a"]?.requests == 5)
        #expect(summary["a"]?.errors == 1)
    }

    @Test func tailEvents() throws {
        let e = TailEvent(
            try JSON.parse(
                #"{"outcome":"ok","eventTimestamp":1791633600000,"event":{"request":{"method":"GET","url":"https://x.dev/"},"response":{"status":200}},"logs":[{"level":"log","message":["hello",1]}],"exceptions":[{"name":"Error","message":"boom"}]}"#))
        #expect(e.title == "GET https://x.dev/")
        #expect(e.status == 200)
        #expect(e.logs.first?.message == "hello 1")
        #expect(e.exceptions == ["Error: boom"])
        #expect(e.at == Date(timeIntervalSince1970: 1_791_633_600))
        let cron = TailEvent(["outcome": "ok", "event": ["cron": "*/5 * * * *"]])
        #expect(cron.title == "cron */5 * * * *")
        #expect(cron.searchText.contains("cron"))
    }

    @Test func templatesAreModules() {
        #expect(Workers.templates.count == 5)
        #expect(Workers.templates.allSatisfy { $0.code.contains("export default") })
        #expect(Workers.templates[1].code.contains("${request.method}"))
        #expect(Workers.scriptPath("acc", "my worker") == "/accounts/acc/workers/scripts/my%20worker")
    }
}

@Suite struct StorageTests {
    @Test func kvText() {
        #expect(KV.looksText(Data("héllo".utf8)))
        #expect(!KV.looksText(Data([0x68, 0x00, 0x69])))
        #expect(!KV.looksText(Data([0xff, 0xfe, 0xfd, 0xfc, 0xfb])))
        // A character cut at the 2048-byte sample boundary is still text.
        let long = String(repeating: "a", count: 2047) + "é"
        #expect(KV.looksText(Data(long.utf8)))
    }

    @Test func r2Listing() {
        let res = CFResponse(
            statusCode: 200,
            result: [["key": "docs/", "size": 0], ["key": "docs/a.txt", "size": 3]],
            resultInfo: ["delimited": ["docs/img/"], "is_truncated": "true", "cursor": "c1"], messages: [], headers: [:],
            raw: .null, duration: 0)
        let l = R2.parseListing(res, prefix: "docs/")
        #expect(l.objects.map { $0["key"].string } == ["docs/a.txt"])
        #expect(l.folders == ["docs/img/"])
        #expect(l.cursor == "c1")
        #expect(R2.object("a", "b", "docs/a b.txt") == "/accounts/a/r2/buckets/b/objects/docs%2Fa%20b.txt")
        #expect(R2.mimeType(for: "X.PNG") == "image/png")
        #expect(R2.mimeType(for: "blob") == "application/octet-stream")
        #expect(R2.previewKind(contentType: "application/json") == .text)
        #expect(R2.previewKind(contentType: "image/webp") == .image)
        #expect(R2.previewKind(contentType: "application/zip") == nil)
        #expect(R2.symbol(for: "a/b.mp4") == "film")
        #expect(R2.parseBuckets(["buckets": [["name": "x"]]]).count == 1)
    }

    @Test func d1Results() {
        let r = D1.parseRaw([
            [
                "results": ["columns": ["id", "name"], "rows": [[1, "a"], [2, nil]]],
                "meta": ["duration": 0.5, "rows_read": 2, "changes": 0],
            ]
        ])
        #expect(r.count == 1)
        #expect(r[0].columns == ["id", "name"])
        #expect(D1.cell(r[0].rows[1][1]) == "NULL")
        #expect(r[0].summary.contains("0.50 ms"))
        #expect(D1.isDestructive("delete from t"))
        #expect(D1.isDestructive("ALTER TABLE t ADD c"))
        #expect(!D1.isDestructive("select * from deleted_items"))
        #expect(D1.changesSchema("CREATE TABLE x (a)"))
        #expect(D1.quote(#"a"b"#) == #""a""b""#)
    }

    @Test func workersAI() throws {
        #expect(WorkersAI.reply(["response": "hi"]) == "hi")
        #expect(WorkersAI.reply(["choices": [["message": ["content": "yo"]]]]) == "yo")
        #expect(WorkersAI.task(["task": ["name": "Text Generation"]]) == "Text Generation")
        let png = Data([0x89, 0x50, 0x4e, 0x47])
        #expect(try WorkersAI.image(data: png, contentType: "image/png") == png)
        let json: JSON = ["success": true, "result": ["image": .string(png.base64EncodedString())]]
        #expect(try WorkersAI.image(data: json.encoded(), contentType: "application/json") == png)
        let failed: JSON = ["success": false, "errors": [["code": 5006, "message": "bad prompt"]]]
        #expect(throws: CFAPIError.self) { try WorkersAI.image(data: failed.encoded(), contentType: "application/json") }
        #expect(WorkersAI.example(task: "Translation")["target_lang"].string == "chinese")
        #expect(Pages.url("my.pages.dev")?.absoluteString == "https://my.pages.dev")
        #expect(Pages.url(nil) == nil)
    }
}
