import Foundation
import Testing
@testable import CirrusKit

@Suite struct JSONTests {
    @Test func parseAndAccess() throws {
        let j = try JSON.parse(#"{"a":[1,2.5,"3",true,null],"b":{"c":"d"}}"#)
        #expect(j["a"][0].int == 1)
        #expect(j["a"][1].double == 2.5)
        #expect(j["a"][2].int == 3)
        #expect(j["a"][3].isTrue)
        #expect(j["a"][4].isNull)
        #expect(j["a"][9].isNull)
        #expect(j["b"]["c"].string == "d")
        #expect(j["missing"]["deeper"].isNull)
        #expect(j.pick("b.c").string == "d")
        #expect(j.pick("a.1").double == 2.5)
    }

    @Test func numbersKeepTheirKind() throws {
        #expect(try JSON.parse("1") == .int(1))
        #expect(try JSON.parse("1.5") == .double(1.5))
        #expect(try JSON.parse("true") == .bool(true))
        #expect(JSON.double(3).int == 3)
        #expect(JSON.double(3.5).int == nil)
    }

    @Test func roundTripAndText() throws {
        let j: JSON = ["name": "x", "n": 2, "list": [1, "two"], "nothing": nil]
        #expect(try JSON.parse(j.encoded()) == j)
        #expect(JSON.int(42).text == "42")
        #expect(JSON.null.text(or: "-") == "-")
        #expect(j.setting("n", to: 3)["n"].int == 3)
        #expect(j.merging(["extra": true])["extra"].isTrue)
        #expect(j.compactString.contains("\"name\":\"x\""))
        #expect(JSON(any: ["a": [1, "b"]] as [String: Any]) == ["a": [1, "b"]])
    }
}

@Suite struct DNSTests {
    @Test func validation() {
        #expect(DNSCatalog.validate(type: "A", content: "203.0.113.10") == nil)
        #expect(DNSCatalog.validate(type: "A", content: "203.0.113.256") != nil)
        #expect(DNSCatalog.validate(type: "A", content: "1.2.3") != nil)
        #expect(DNSCatalog.validate(type: "AAAA", content: "2001:db8::1") == nil)
        #expect(DNSCatalog.validate(type: "AAAA", content: "1.2.3.4") != nil)
        #expect(DNSCatalog.validate(type: "TXT", content: "  ") != nil)
    }

    @Test func relativeNames() {
        #expect(DNSCatalog.relativeName("example.com", zone: "example.com") == "@")
        #expect(DNSCatalog.relativeName("www.example.com", zone: "example.com") == "www")
        #expect(DNSCatalog.relativeName("other.net", zone: "example.com") == "other.net")
    }

    @Test func simpleRecordBody() {
        var d = DNSRecordDraft(type: "A")
        d.name = "@"
        d.content = " 203.0.113.10 "
        d.tags = "env:prod, , team:web"
        d.proxied = false
        let b = d.body(zone: "example.com")
        #expect(b["name"].string == "example.com")
        #expect(b["content"].string == "203.0.113.10")
        #expect(b["proxied"].bool == false)
        #expect(b["ttl"].int == 1)
        #expect(b["tags"].strings == ["env:prod", "team:web"])
        #expect(b["priority"].isNull)
        #expect(b["data"].isNull)
    }

    @Test func mxAndCustomTTL() {
        var d = DNSRecordDraft(type: "MX")
        d.name = "mail"
        d.content = "mx.example.net"
        d.priority = ""
        d.ttl = -1
        d.customTTL = "420"
        let b = d.body(zone: "example.com")
        #expect(b["priority"].int == 10)
        #expect(b["ttl"].int == 420)
        #expect(b["proxied"].isNull)
    }

    @Test func structuredRecordBody() {
        var d = DNSRecordDraft(type: "CAA")
        d.name = "@"
        d.data = ["flags": "0", "value": "letsencrypt.org"]
        let b = d.body(zone: "example.com")
        #expect(b["data"] == ["flags": 0, "tag": "issue", "value": "letsencrypt.org"])
        #expect(b["content"].isNull)
    }

    @Test func editorStateFromRecord() {
        let r: JSON = ["type": "CNAME", "name": "www.example.com", "content": "example.net", "proxied": true,
                       "ttl": 420, "tags": ["a", "b"], "settings": ["flatten_cname": true]]
        let d = DNSRecordDraft(record: r, zone: "example.com")
        #expect(d.name == "www")
        #expect(d.ttl == -1 && d.customTTL == "420")
        #expect(d.tags == "a, b")
        #expect(d.flattenCNAME)
        #expect(d.body(zone: "example.com")["settings"]["flatten_cname"].isTrue)
        #expect(d.body(zone: "example.com")["name"].string == "www")
    }
}

@Suite struct TrafficTests {
    @Test func parsesDailyGroups() throws {
        let data = try JSON.parse(
            """
            {"viewer":{"zones":[{"httpRequests1dGroups":[
              {"dimensions":{"date":"2026-10-09"},"uniq":{"uniques":40},
               "sum":{"requests":100,"cachedRequests":25,"bytes":2048,"cachedBytes":1024,"threats":1,"pageViews":60,
                      "responseStatusMap":[{"edgeResponseStatus":200,"requests":90},{"edgeResponseStatus":404,"requests":10}],
                      "countryMap":[{"clientCountryName":"CN","requests":70},{"clientCountryName":"US","requests":30}]}},
              {"dimensions":{"date":"2026-10-10"},"uniq":{"uniques":55},
               "sum":{"requests":300,"cachedRequests":75,"bytes":0,"cachedBytes":0,"threats":0,"pageViews":10,
                      "responseStatusMap":[{"edgeResponseStatus":200,"requests":300}],
                      "countryMap":[{"clientCountryName":"US","requests":300}]}}
            ]}]}}
            """)
        let t = ZoneTraffic.parse(data, hourly: false)
        #expect(t.points.count == 2)
        #expect(t.requests == 400)
        #expect(t.cacheRatio == 0.25)
        #expect(t.uniques == 55)
        #expect(t.statusCodes["200"] == 390)
        #expect(ZoneTraffic.top(t.countries, 1).first?.0 == "US")
        #expect(ISODate.format(t.points[0].date) == "2026-10-09T00:00:00.000Z")
    }

    @Test func emptyDataIsEmpty() {
        let t = ZoneTraffic.parse(.null, hourly: true)
        #expect(t.points.isEmpty && t.cacheRatio == 0)
    }

    @Test func queryWindows() {
        let now = ISODate.parse("2026-10-10T15:42:00Z")!
        let daily = ZoneTraffic.variables(zoneId: "z", days: 7, now: now)
        #expect(daily["zoneTag"].string == "z")
        #expect(daily.compactString.contains("2026-10-04"))
        let hourly = ZoneTraffic.variables(zoneId: "z", hours: 24, now: now)
        #expect(hourly.compactString.contains("2026-10-09T16:00:00Z"))
        #expect(hourly.compactString.contains("2026-10-10T16:00:00Z"))
    }
}

@Suite struct FormatTests {
    @Test func bytes() {
        #expect(Format.bytes(512) == "512 B")
        #expect(Format.bytes(1536) == "1.5 KB")
        #expect(Format.bytes(5 * 1024 * 1024 * 1024) == "5.0 GB")
        #expect(Format.bytes(nil) == "—")
    }

    @Test func ttlAndPercent() {
        #expect(Format.ttl(300) == "5m")
        #expect(Format.ttl(7200) == "2h")
        #expect(Format.ttl(86400) == "1d")
        #expect(Format.ttl(45) == "45s")
        #expect(Format.percent(0.256) == "25.6%")
    }

    @Test func dates() {
        #expect(Format.date(.int(1_791_633_600)) == ISODate.parse("2026-10-10T12:00:00Z"))
        #expect(Format.date(.int(1_791_633_600_000)) == ISODate.parse("2026-10-10T12:00:00Z"))
        #expect(Format.date(.string("nope")) == nil)
        #expect(ISODate.parse("2026-10-10")!.timeIntervalSince1970 == 1_791_590_400)
    }

    @Test func pathTemplates() {
        let ids: [String: String?] = ["account_id": "acc", "zone_id": "z/1", "script_name": nil]
        #expect(expandPath("/accounts/{account_id}/workers", ids: ids) == "/accounts/acc/workers")
        #expect(expandPath("/zones/{zone_identifier}/dns_records", ids: ids) == "/zones/z%2F1/dns_records")
        #expect(expandPath("/accounts/{account_id}/workers/scripts/{script_name}", ids: ids)
            == "/accounts/acc/workers/scripts/{script_name}")
    }
}

@Suite struct MultipartTests {
    @Test func roundTrip() {
        var form = MultipartForm(boundary: "b0undary")
        form.add("metadata", #"{"main_module":"worker.js"}"#)
        form.addFile("worker.js", filename: "worker.js", contentType: "application/javascript+module",
                     data: Data("export default {}".utf8))
        #expect(form.contentType == "multipart/form-data; boundary=b0undary")
        #expect(multipartBoundary(form.contentType) == "b0undary")
        let parts = parseMultipart(form.body, boundary: "b0undary")
        #expect(parts.count == 2)
        #expect(parts[0].name == "metadata")
        #expect(parts[0].text == #"{"main_module":"worker.js"}"#)
        #expect(parts[1].filename == "worker.js")
        #expect(parts[1].contentType == "application/javascript+module")
        #expect(parts[1].text == "export default {}")
    }

    @Test func quotedBoundary() {
        #expect(multipartBoundary(#"multipart/form-data; boundary="abc def""#) == "abc def")
        #expect(multipartBoundary("application/json") == nil)
    }
}

@Suite struct CatalogTests {
    @Test func zoneSettingsAreGrouped() {
        #expect(ZoneSettingsCatalog.group(of: "ssl") == .ssl)
        #expect(ZoneSettingsCatalog.group(of: "made_up") == .other)
        let ids = ZoneSettingsCatalog.ids(in: .ssl, of: ["min_tls_version", "ssl", "made_up"])
        #expect(ids == ["ssl", "min_tls_version"])
        let index = ZoneSettingsCatalog.index([["id": "ssl", "value": "full"], ["id": "brotli", "value": "on"]])
        #expect(index["ssl"]?["value"].string == "full")
    }

    @Test func storeChannel() {
        #expect(StoreChannel(setting: "appstore") == .appStore)
        #expect(StoreChannel(setting: "direct") == .license)
        #expect(StoreChannel(setting: nil) == .none)
        #expect(proProductID == "cirrus_pro_lifetime")
    }

    @Test func language() {
        #expect(AppLanguage.resolve("zh") == .zh)
        #expect(AppLanguage.resolve("zh_Hant") == .zh)
        #expect(AppLanguage.resolve("en") == .en)
    }
}

@Suite struct StatusToneTests {
    @Test func tones() {
        #expect(StatusTone.of("Active") == .good)
        #expect(StatusTone.of("pending_validation") == .warn)
        #expect(StatusTone.of("expired") == .bad)
        #expect(StatusTone.of(nil) == .neutral)
        #expect(StatusTone.of("whatever") == .neutral)
    }
}
