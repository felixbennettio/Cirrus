import '../api/cf_client.dart';
import '../api/cf_exception.dart';
import 'credential.dart';

/// Result of checking a credential against the API.
class VerifyResult {
  const VerifyResult({
    required this.ok,
    this.status,
    this.tokenId,
    this.expiresOn,
    this.email,
    this.accounts = const [],
    this.error,
  });

  final bool ok;
  final String? status;
  final String? tokenId;
  final String? expiresOn;
  final String? email;
  final List<Map<String, dynamic>> accounts;
  final String? error;
}

/// Verifies a profile. API tokens use the token verify endpoints (user
/// tokens first, then account-owned tokens); global keys use `/user`; OAuth
/// profiles must pass a [client] that carries their session.
Future<VerifyResult> verifyProfile(Profile profile, {CfClient? client}) async {
  final c = client ?? CfClient(profile);
  try {
    String? status;
    String? tokenId;
    String? expires;
    String? email;
    if (profile.kind == AuthKind.apiToken) {
      Map? r;
      if (profile.accountId != null && profile.accountId!.isNotEmpty) {
        r = await c.get('/accounts/${profile.accountId}/tokens/verify') as Map?;
      } else {
        try {
          r = await c.get('/user/tokens/verify') as Map?;
        } on CfApiException {
          // Account-owned tokens are rejected by /user/tokens/verify. Find an
          // account the token can see and verify there instead.
          final accounts = await c.list('/accounts', perPage: 50, maxItems: 50);
          if (accounts.isEmpty) rethrow;
          final id = accounts.first['id'] as String;
          r = await c.get('/accounts/$id/tokens/verify') as Map?;
          if (r == null) rethrow;
        }
      }
      status = r?['status'] as String?;
      tokenId = r?['id'] as String?;
      expires = r?['expires_on'] as String?;
      if (status != null && status != 'active') {
        return VerifyResult(ok: false, status: status, tokenId: tokenId, error: 'Token status: $status');
      }
    } else if (profile.kind == AuthKind.oauth) {
      // OAuth grants may not include user details; only an auth failure is fatal.
      try {
        final user = await c.get('/user') as Map?;
        email = user?['email'] as String?;
      } on CfApiException catch (e) {
        if (e.isAuthError) rethrow;
      }
      status = 'active';
    } else {
      final user = await c.get('/user') as Map?;
      email = user?['email'] as String?;
      status = 'active';
    }
    List<Map<String, dynamic>> accounts = const [];
    try {
      accounts = await c.list('/accounts', perPage: 50, maxItems: 200);
    } catch (_) {}
    return VerifyResult(
      ok: true,
      status: status,
      tokenId: tokenId,
      expiresOn: expires,
      email: email,
      accounts: accounts,
    );
  } on CfApiException catch (e) {
    return VerifyResult(ok: false, error: e.summary);
  } catch (e) {
    return VerifyResult(ok: false, error: e.toString());
  }
}
