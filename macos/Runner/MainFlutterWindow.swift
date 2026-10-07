import Cocoa
import FlutterMacOS

class MainFlutterWindow: NSWindow {
  override func awakeFromNib() {
    let flutterViewController = FlutterViewController()
    let windowFrame = self.frame
    self.contentViewController = flutterViewController
    self.setFrame(windowFrame, display: true)

    RegisterGeneratedPlugins(registry: flutterViewController)
    flutterViewController.registrar(forPlugin: "CirrusGlass")
      .register(GlassViewFactory(), withId: "io.felixbennett.cirrus/glass")

    super.awakeFromNib()
  }
}

/// Apple's glass material behind Flutter content (`lib/ui/widgets/native_glass.dart`):
/// Liquid Glass (`NSGlassEffectView`) on macOS 26, the system blur materials before.
final class GlassViewFactory: NSObject, FlutterPlatformViewFactory {
  func create(withViewIdentifier viewId: Int64, arguments args: Any?) -> NSView {
    let arguments = args as? [String: Any] ?? [:]
    let radius = CGFloat((arguments["cornerRadius"] as? NSNumber)?.doubleValue ?? 0)
    let dark = (arguments["dark"] as? NSNumber)?.boolValue ?? false
    let bar = (arguments["kind"] as? String) == "bar"
    // Follow the app's theme, which may differ from the system's.
    let appearance = NSAppearance(named: dark ? .darkAqua : .aqua)

    if #available(macOS 26.0, *) {
      let glass = PassthroughGlassView()
      glass.cornerRadius = radius
      glass.appearance = appearance
      return glass
    }
    let blur = PassthroughVisualEffectView()
    blur.material = bar ? .headerView : .popover
    blur.blendingMode = .withinWindow
    blur.state = .active
    blur.appearance = appearance
    blur.wantsLayer = true
    blur.layer?.cornerRadius = radius
    blur.layer?.cornerCurve = .continuous
    blur.layer?.masksToBounds = radius > 0
    return blur
  }

  func createArgsCodec() -> (FlutterMessageCodec & NSObjectProtocol)? {
    FlutterStandardMessageCodec.sharedInstance()
  }
}

// Clicks belong to the Flutter content drawn over the glass.

@available(macOS 26.0, *)
final class PassthroughGlassView: NSGlassEffectView {
  override func hitTest(_ point: NSPoint) -> NSView? { nil }
}

final class PassthroughVisualEffectView: NSVisualEffectView {
  override func hitTest(_ point: NSPoint) -> NSView? { nil }
}
