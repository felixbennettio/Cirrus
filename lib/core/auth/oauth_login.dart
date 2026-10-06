import 'dart:async';
import 'dart:io';

import 'package:app_links/app_links.dart';
import 'package:url_launcher/url_launcher.dart';

import 'oauth.dart';

/// Custom scheme used on iOS, Android and macOS (RFC 8252 §7.1). It must be
/// registered as a redirect URL on the OAuth client, together with
/// [loopbackRedirectTemplate].
const oauthAppScheme = 'io.felixbennett.cirrus';
final appSchemeRedirect = Uri.parse('$oauthAppScheme:/oauth/callback');

/// Loopback redirect used on Windows and Linux (RFC 8252 §7.3). The
/// authorization server accepts any port for a registered loopback IP URL.
const loopbackRedirectTemplate = 'http://127.0.0.1/oauth/callback';

/// Receives the authorization response for one sign-in attempt.
abstract class OAuthRedirectReceiver {
  /// Prepares to receive the response for the request carrying [state] and
  /// returns the redirect URI to send.
  Future<Uri> start({required String state});

  /// Completes with the full redirect URL (including `code`/`state`).
  Future<Uri> callback();

  Future<void> close();
}

/// Listens on `127.0.0.1:<ephemeral port>` for the browser redirect.
class LoopbackReceiver implements OAuthRedirectReceiver {
  LoopbackReceiver({this.successHtml = _successHtml});

  final String successHtml;
  HttpServer? _server;
  final _result = Completer<Uri>();

  @override
  Future<Uri> start({required String state}) async {
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    _server = server;
    final redirect = Uri.parse(loopbackRedirectTemplate).replace(port: server.port);
    server.listen((req) async {
      if (req.uri.path != redirect.path) {
        req.response.statusCode = HttpStatus.notFound;
        await req.response.close();
        return;
      }
      req.response
        ..statusCode = HttpStatus.ok
        ..headers.contentType = ContentType.html
        ..write(successHtml);
      await req.response.close();
      if (!_result.isCompleted) _result.complete(redirect.replace(query: req.uri.query));
    });
    return redirect;
  }

  @override
  Future<Uri> callback() => _result.future;

  @override
  Future<void> close() async {
    await _server?.close(force: true);
    _server = null;
  }
}

/// Waits for the `io.felixbennett.cirrus:/oauth/callback` deep link.
class AppLinkReceiver implements OAuthRedirectReceiver {
  AppLinkReceiver({this.links});

  /// Overrides the platform link stream (tests).
  final Stream<Uri>? links;
  StreamSubscription<Uri>? _sub;
  final _result = Completer<Uri>();

  @override
  Future<Uri> start({required String state}) async {
    _sub = (links ?? AppLinks().uriLinkStream).listen((uri) {
      // The stream replays the link that launched the app, which may be the
      // callback of an earlier, abandoned sign-in: only accept this request's.
      if (uri.scheme == appSchemeRedirect.scheme &&
          uri.path == appSchemeRedirect.path &&
          uri.queryParameters['state'] == state &&
          !_result.isCompleted) {
        _result.complete(uri);
      }
    });
    return appSchemeRedirect;
  }

  @override
  Future<Uri> callback() => _result.future;

  @override
  Future<void> close() async => _sub?.cancel();
}

/// The receiver that suits the current platform.
OAuthRedirectReceiver platformReceiver() =>
    Platform.isWindows || Platform.isLinux ? LoopbackReceiver() : AppLinkReceiver();

/// Opens [url] in the system browser.
Future<void> openInBrowser(Uri url) async {
  final ok = await launchUrl(url, mode: LaunchMode.externalApplication);
  if (!ok) throw OAuthException('browser_unavailable', 'Could not open $url');
}

/// Runs the full sign-in: opens the Cloudflare consent page, waits for the
/// redirect, checks `state` and exchanges the code for tokens.
///
/// Completing [cancel] aborts the wait (e.g. the user gave up in the browser).
Future<OAuthTokens> signInWithCloudflare(
  OAuthConfig config, {
  OAuthApi? api,
  OAuthRedirectReceiver? receiver,
  Future<void> Function(Uri url) launch = openInBrowser,
  Future<void>? cancel,
  Duration timeout = const Duration(minutes: 10),
}) async {
  final oauth = api ?? OAuthApi();
  final rx = receiver ?? platformReceiver();
  final pkce = Pkce.generate();
  final state = randomUrlSafe(32);
  try {
    final redirect = await rx.start(state: state);
    await launch(oauth.authorizeUri(config, redirectUri: redirect, state: state, pkce: pkce));
    final result = await Future.any([
      rx.callback(),
      if (cancel != null) cancel.then<Uri>((_) => throw const OAuthException('cancelled')),
    ]).timeout(timeout, onTimeout: () => throw const OAuthException('timeout', 'No response from the browser.'));
    final q = result.queryParameters;
    if (q['error'] != null) throw OAuthException(q['error']!, q['error_description']);
    if (q['state'] != state) {
      throw const OAuthException('state_mismatch', 'The authorization response did not match this request.');
    }
    final code = q['code'];
    if (code == null || code.isEmpty) throw const OAuthException('invalid_response', 'No authorization code.');
    return await oauth.exchangeCode(config, code: code, redirectUri: redirect, pkce: pkce);
  } finally {
    await rx.close();
  }
}

const _successHtml = '''<!doctype html><html><head><meta charset="utf-8"><title>Cirrus</title>
<style>body{font-family:system-ui,sans-serif;display:flex;align-items:center;justify-content:center;height:90vh;margin:0;color:#222}
div{text-align:center}h1{font-size:22px;margin-bottom:8px}p{color:#666}</style></head>
<body><div><h1>Signed in to Cirrus</h1><p>You can close this tab and return to the app.</p>
<p>已登录 Cirrus，可以关闭此页面并返回应用。</p></div></body></html>''';
