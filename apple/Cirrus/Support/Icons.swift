import Foundation

/// SF Symbols for the Material icon names in `resources.json`.
enum Icons {
    static func symbol(_ material: String) -> String {
        let name = material.replacingOccurrences(of: "_outlined", with: "")
        return map[name] ?? "square.grid.2x2"
    }

    private static let map: [String: String] = [
        "account_tree": "list.bullet.indent", "admin_panel_settings": "person.badge.shield.checkmark",
        "alt_route": "arrow.triangle.branch", "apps": "square.grid.2x2", "autorenew": "arrow.clockwise",
        "badge": "person.text.rectangle", "balance": "scalemass", "block": "nosign", "bookmark_border": "bookmark",
        "cable": "cable.connector", "call_received": "arrow.down.left", "call_split": "arrow.triangle.branch",
        "category": "square.on.circle", "code": "chevron.left.forwardslash.chevron.right", "corporate_fare": "building.2",
        "credit_card": "creditcard", "data_object": "curlybraces", "delete_sweep": "trash.slash",
        "description": "doc.text", "dns": "server.rack", "download": "arrow.down.circle", "edit_note": "square.and.pencil",
        "enhanced_encryption": "lock.doc", "extension": "puzzlepiece.extension", "groups_2": "person.3",
        "health_and_safety": "cross.case", "history": "clock.arrow.circlepath", "hourglass_top": "hourglass",
        "hub": "point.3.connected.trianglepath.dotted", "image": "photo", "info_outline": "info.circle",
        "inventory_2": "archivebox", "javascript": "curlybraces.square", "key_off": "key.slash", "lan": "network",
        "laptop_mac": "laptopcomputer", "layers": "square.3.layers.3d", "linear_scale": "slider.horizontal.below.rectangle",
        "link": "link", "list": "list.bullet", "list_alt": "list.bullet.rectangle", "live_tv": "tv",
        "local_fire_department": "flame", "location_on": "mappin.and.ellipse", "lock_clock": "lock.circle",
        "login": "rectangle.portrait.and.arrow.right", "logout": "rectangle.portrait.and.arrow.forward",
        "mail_outline": "envelope", "manage_accounts": "person.crop.circle.badge.checkmark",
        "manage_history": "clock.badge.checkmark", "merge_type": "arrow.triangle.merge", "monitor_heart": "waveform.path.ecg",
        "monitor": "display", "movie": "film", "network_check": "network.badge.shield.half.filled",
        "notification_important": "bell.badge", "notifications_active": "bell.and.waves.left.and.right",
        "password": "key.horizontal", "person": "person", "person_outline": "person", "phonelink_setup": "iphone.gen3",
        "pin": "pin", "play_circle_outline": "play.circle", "policy": "checkmark.shield", "privacy_tip": "hand.raised",
        "queue": "tray.2", "receipt_long": "list.bullet.rectangle.portrait", "receipt": "doc.plaintext", "restore": "arrow.uturn.backward",
        "route": "point.topleft.down.to.point.bottomright.curvepath", "router": "wifi.router", "rule_folder": "folder.badge.gearshape",
        "scatter_plot": "chart.dots.scatter", "search": "magnifyingglass", "security": "lock.shield", "sell": "tag",
        "send": "paperplane", "settings_applications": "gearshape.2", "settings_input_antenna": "antenna.radiowaves.left.and.right",
        "settings_suggest": "gearshape.arrow.triangle.2.circlepath", "smart_toy": "cpu", "speed": "speedometer",
        "storefront": "storefront", "swap_horiz": "arrow.left.arrow.right", "transform": "wand.and.rays", "tune": "slider.horizontal.3",
        "update": "arrow.triangle.2.circlepath", "upload": "arrow.up.circle", "upload_file": "doc.badge.arrow.up",
        "verified": "checkmark.seal", "verified_user": "checkmark.shield", "vpn_key": "key", "web": "globe",
        "web_asset": "macwindow", "webhook": "arrow.triangle.pull", "widgets": "square.grid.3x2", "wifi": "wifi",
        "workspace_premium": "rosette", "public_off": "globe.badge.chevron.backward", "person_off": "person.slash",
        "lock_person": "lock.rectangle",
    ]
}
