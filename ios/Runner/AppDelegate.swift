import Flutter
import UIKit

@main
@objc class AppDelegate: FlutterAppDelegate, FlutterImplicitEngineDelegate {
  override func application(
    _ application: UIApplication,
    didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?
  ) -> Bool {
    return super.application(application, didFinishLaunchingWithOptions: launchOptions)
  }

  func didInitializeImplicitFlutterEngine(_ engineBridge: FlutterImplicitEngineBridge) {
    GeneratedPluginRegistrant.register(with: engineBridge.pluginRegistry)
    engineBridge.pluginRegistry.registrar(forPlugin: "CirrusGlass")?
      .register(GlassViewFactory(), withId: "io.felixbennett.cirrus/glass")
  }
}

/// Apple's glass material behind Flutter content (`lib/ui/widgets/native_glass.dart`):
/// Liquid Glass (`UIGlassEffect`) on iOS 26, the system blur materials before.
final class GlassViewFactory: NSObject, FlutterPlatformViewFactory {
  func create(withFrame frame: CGRect, viewIdentifier viewId: Int64, arguments args: Any?) -> FlutterPlatformView {
    GlassPlatformView(frame: frame, arguments: args as? [String: Any] ?? [:])
  }

  func createArgsCodec() -> FlutterMessageCodec & NSObjectProtocol {
    FlutterStandardMessageCodec.sharedInstance()
  }
}

final class GlassPlatformView: NSObject, FlutterPlatformView {
  private let effectView: UIVisualEffectView

  init(frame: CGRect, arguments: [String: Any]) {
    let radius = CGFloat((arguments["cornerRadius"] as? NSNumber)?.doubleValue ?? 0)
    let dark = (arguments["dark"] as? NSNumber)?.boolValue ?? false
    let bar = (arguments["kind"] as? String) == "bar"

    effectView = UIVisualEffectView(effect: nil)
    effectView.frame = frame
    effectView.autoresizingMask = [.flexibleWidth, .flexibleHeight]
    // Touches belong to the Flutter content drawn over the glass.
    effectView.isUserInteractionEnabled = false
    // Follow the app's theme, which may differ from the system's.
    effectView.overrideUserInterfaceStyle = dark ? .dark : .light
    if #available(iOS 26.0, *) {
      effectView.effect = UIGlassEffect()
      effectView.cornerConfiguration = .corners(radius: .fixed(radius))
    } else {
      effectView.effect = UIBlurEffect(style: bar ? .systemChromeMaterial : .systemMaterial)
      effectView.layer.cornerRadius = radius
      effectView.layer.cornerCurve = .continuous
      effectView.clipsToBounds = radius > 0
    }
    super.init()
  }

  func view() -> UIView { effectView }
}
