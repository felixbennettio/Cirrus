import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:cirrus/core/billing/billing.dart';
import 'package:cirrus/core/licensing/device_identity.dart';
import 'package:cirrus/core/licensing/license_api.dart';
import 'package:cirrus/core/licensing/license_config.dart';
import 'package:cirrus/core/licensing/license_store.dart';
import 'package:cirrus/core/licensing/license_token.dart';
import 'package:cryptography/cryptography.dart';
import 'package:dio/dio.dart';
import 'package:flutter_riverpod/misc.dart';
import 'package:package_info_plus/package_info_plus.dart';

import 'fake_api.dart';

/// `docs/licensing_test_vector.json`, shared with the licence server's tests.
final licenseVector = Map<String, dynamic>.from(
  jsonDecode(File('docs/licensing_test_vector.json').readAsStringSync()) as Map,
);

final vectorSeed = [
  for (var i = 0; i < 64; i += 2) int.parse((licenseVector['seed_hex'] as String).substring(i, i + 2), radix: 16),
];

final vectorPublicKey = licenseVector['public_key_base64'] as String;

/// The device the vector's token was issued for.
final vectorDevice = DeviceIdentity.fromRaw(licenseVector['machine_id'] as String, name: 'test-host');

final testLicenseConfig = LicenseConfig.parse(server: 'https://licence.test/', publicKey: vectorPublicKey);

/// A Linux key and a Windows key, both in canonical form.
const linuxKey = 'CIRRUS-7K3QD-M2XRT-9VB4N-HJ6WP';
const windowsKey = 'CIRRUS-A8F2K-QW3ZT-0P9MX-RB7CE';

/// The app version reported on activation.
void mockAppVersion() => PackageInfo.setMockInitialValues(
  appName: 'Cirrus',
  packageName: 'io.felixbennett.cirrus',
  version: '1.0.0',
  buildNumber: '2',
  buildSignature: '',
);

Map<String, Object?> tokenPayload({String platform = 'linux', String? device, Object v = 1}) => {
  'v': v,
  'lic': 'lic_test0001',
  'product': 'cirrus-$platform',
  'platform': platform,
  'device': device ?? vectorDevice.id,
  'iat': 1767225600,
  'owner': 'q***@example.com',
};

/// Signs [payload] like the licence server: with the vector's key unless
/// another [seed] is given.
Future<String> signLicenseToken(Map<String, Object?> payload, {List<int>? seed}) async {
  final bytes = utf8.encode(jsonEncode(payload));
  final algorithm = Ed25519();
  final signature = await algorithm.sign(bytes, keyPair: await algorithm.newKeyPairFromSeed(seed ?? vectorSeed));
  return '${encodeBase64Url(bytes)}.${encodeBase64Url(signature.bytes)}';
}

/// A licence held by [FakeLicenseServer].
class FakeLicence {
  FakeLicence({required this.platform, this.maxDevices = 1});

  final String platform;
  final int maxDevices;
  bool revoked = false;

  /// Activated devices: id → name.
  final devices = <String, String>{};
}

/// In-memory licence server following `docs/licensing.md`.
class FakeLicenseServer implements HttpClientAdapter {
  final licences = <String, FakeLicence>{};
  final calls = <FakeCall>[];
  bool offline = false;

  late final api = LicenseApi(testLicenseConfig.server, dio: Dio()..httpClientAdapter = this);

  List<FakeCall> callsTo(String path) => calls.where((c) => c.uri.path == '/api/v1/$path').toList();

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) async {
    if (offline) throw const SocketException('Network is unreachable');
    final body = Map<String, dynamic>.from(options.data as Map);
    calls.add(FakeCall(options.method, options.uri, Map<String, dynamic>.from(options.headers), body));
    final (status, json) = await _handle(options.uri.path, body);
    return ResponseBody.fromBytes(
      utf8.encode(jsonEncode(json)),
      status,
      headers: {
        'content-type': ['application/json'],
      },
    );
  }

  Future<(int, Map<String, Object?>)> _handle(String path, Map<String, dynamic> body) async {
    (int, Map<String, Object?>) error(int status, String code) => (status, {'error': code, 'message': '错误：$code'});
    final licence = licences[body['license_key']];
    if (licence == null) return error(404, 'invalid_key');
    final device = body['device_id'] as String;
    switch (path) {
      case '/api/v1/activate':
        if (licence.revoked) return error(410, 'revoked');
        if (body['platform'] != licence.platform) return error(403, 'wrong_platform');
        if (!licence.devices.containsKey(device) && licence.devices.length >= licence.maxDevices) {
          return (
            409,
            {
              'error': 'activation_limit',
              'message': '已达到设备上限',
              'devices': [
                for (final name in licence.devices.values) {'name': name, 'activated_at': '2026-01-01T00:00:00Z'},
              ],
            },
          );
        }
        licence.devices[device] = body['device_name'] as String;
        return (
          200,
          {
            'activation': await signLicenseToken(tokenPayload(platform: licence.platform, device: device)),
            'license': {
              'product': 'cirrus-${licence.platform}',
              'platform': licence.platform,
              'max_devices': licence.maxDevices,
              'devices_used': licence.devices.length,
            },
          },
        );
      case '/api/v1/deactivate':
        licence.devices.remove(device);
        return (200, {'ok': true});
      case '/api/v1/validate':
        final status = licence.revoked
            ? 'revoked'
            : licence.devices.containsKey(device)
            ? 'active'
            : 'not_activated';
        return (200, {'status': status});
    }
    return error(404, 'not_found');
  }

  @override
  void close({bool force = false}) {}
}

class MemoryLicenseStore extends LicenseStore {
  StoredLicense? stored;

  @override
  Future<StoredLicense?> load() async => stored;

  @override
  Future<void> save(StoredLicense license) async => stored = license;

  @override
  Future<void> clear() async => stored = null;
}

class FixedDeviceIdentity implements DeviceIdentitySource {
  FixedDeviceIdentity(this.identity);

  final DeviceIdentity identity;

  @override
  Future<DeviceIdentity> read() async => identity;
}

/// Overrides for a licence build on Linux talking to [server].
List<Override> licenseOverrides(
  FakeLicenseServer server, {
  required LicenseStore store,
  DeviceIdentity? device,
  LicenseConfig? config,
}) => [
  storeChannelProvider.overrideWithValue(StoreChannel.license),
  licenseConfigProvider.overrideWithValue(config ?? testLicenseConfig),
  licensePlatformProvider.overrideWithValue(LicensePlatform.linux),
  licenseApiProvider.overrideWithValue(server.api),
  licenseStoreProvider.overrideWithValue(store),
  deviceIdentityProvider.overrideWithValue(FixedDeviceIdentity(device ?? vectorDevice)),
];
