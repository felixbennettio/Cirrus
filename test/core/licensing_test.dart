import 'dart:convert';
import 'dart:io';

import 'package:cirrus/core/billing/billing.dart';
import 'package:cirrus/core/licensing/device_identity.dart';
import 'package:cirrus/core/licensing/license_api.dart';
import 'package:cirrus/core/licensing/license_config.dart';
import 'package:cirrus/core/licensing/license_controller.dart';
import 'package:cirrus/core/licensing/license_key.dart';
import 'package:cirrus/core/licensing/license_store.dart';
import 'package:cirrus/core/licensing/license_token.dart';
import 'package:cirrus/core/settings/app_settings.dart';
import 'package:cryptography/cryptography.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../support/fake_license.dart';

/// Secure storage on a Linux desktop without a Secret Service.
class _NoKeychain extends FlutterSecureStorage {
  const _NoKeychain();

  static Never _fail() => throw PlatformException(code: 'Libsecret error', message: 'No Secret Service');

  @override
  Future<String?> read({
    required String key,
    AppleOptions? iOptions,
    AndroidOptions? aOptions,
    LinuxOptions? lOptions,
    WebOptions? webOptions,
    AppleOptions? mOptions,
    WindowsOptions? wOptions,
  }) async => _fail();

  @override
  Future<void> write({
    required String key,
    required String? value,
    AppleOptions? iOptions,
    AndroidOptions? aOptions,
    LinuxOptions? lOptions,
    WebOptions? webOptions,
    AppleOptions? mOptions,
    WindowsOptions? wOptions,
  }) async => _fail();

  @override
  Future<void> delete({
    required String key,
    AppleOptions? iOptions,
    AndroidOptions? aOptions,
    LinuxOptions? lOptions,
    WebOptions? webOptions,
    AppleOptions? mOptions,
    WindowsOptions? wOptions,
  }) async => _fail();
}

/// Waits for the controller's background work (load, validation).
Future<void> until(bool Function() done) async {
  for (var i = 0; i < 500 && !done(); i++) {
    await Future<void>.delayed(const Duration(milliseconds: 2));
  }
  expect(done(), isTrue, reason: 'timed out');
}

void main() {
  group('activation token', () {
    final verifier = LicenseVerifier(base64.decode(vectorPublicKey));
    final token = licenseVector['token'] as String;
    final deviceId = licenseVector['device_id'] as String;

    Future<TokenRejection?> rejection(
      String token, {
      LicenseVerifier? using,
      LicensePlatform platform = LicensePlatform.linux,
      String? device,
    }) async {
      try {
        await (using ?? verifier).verify(token, platform: platform, deviceId: device ?? deviceId);
        return null;
      } on InvalidTokenException catch (e) {
        return e.reason;
      }
    }

    test('the test vector verifies', () async {
      final p = await verifier.verify(token, platform: LicensePlatform.linux, deviceId: deviceId);
      expect(p.version, 1);
      expect(p.licenseId, 'lic_test0001');
      expect(p.product, 'cirrus-linux');
      expect(p.platform, 'linux');
      expect(p.device, deviceId);
      expect(p.issuedAt, DateTime.utc(2026));
      expect(p.owner, 'q***@example.com');
      expect(utf8.decode(decodeBase64Url(token.split('.').first)!), licenseVector['payload']);
    });

    test('a tampered payload is refused', () async {
      final signature = token.split('.').last;
      final forged = (licenseVector['payload'] as String).replaceFirst('q***@example.com', 'x***@example.com');
      expect(await rejection('${encodeBase64Url(utf8.encode(forged))}.$signature'), TokenRejection.badSignature);
    });

    test('a tampered signature is refused', () async {
      final [payload, signature] = token.split('.');
      final bytes = decodeBase64Url(signature)!..[10] ^= 0x01;
      expect(await rejection('$payload.${encodeBase64Url(bytes)}'), TokenRejection.badSignature);
    });

    test('a token for another device is refused', () async {
      expect(await rejection(token, device: deviceIdFor('another machine')), TokenRejection.wrongDevice);
    });

    test('a token for another platform is refused', () async {
      expect(await rejection(token, platform: LicensePlatform.windows), TokenRejection.wrongPlatform);
    });

    test('another public key verifies nothing', () async {
      final other = await (await Ed25519().newKeyPairFromSeed(List.filled(32, 7))).extractPublicKey();
      expect(await rejection(token, using: LicenseVerifier(other.bytes)), TokenRejection.badSignature);
    });

    test('malformed tokens and other versions are refused', () async {
      for (final bad in ['', 'abc', 'a.b.c', '${token.split('.').first}.', '$token=', token.replaceAll('-', '+')]) {
        expect(await rejection(bad), TokenRejection.malformed, reason: bad);
      }
      expect(await rejection(await signLicenseToken(tokenPayload(v: 2))), TokenRejection.unsupportedVersion);
      expect(await rejection(await signLicenseToken(tokenPayload(v: '1'))), TokenRejection.unsupportedVersion);
    });

    test('tokens newly signed with the vector key verify for their platform', () async {
      final windows = await signLicenseToken(tokenPayload(platform: 'windows'));
      expect(await rejection(windows, platform: LicensePlatform.windows), isNull);
      expect(await rejection(windows), TokenRejection.wrongPlatform);
    });
  });

  group('device id', () {
    test('hashes the machine id as in the test vector', () {
      expect(deviceIdFor(licenseVector['machine_id'] as String), licenseVector['device_id']);
      expect(deviceIdFor('  ${licenseVector['machine_id']}\n'), licenseVector['device_id']);
      expect(vectorDevice.id, licenseVector['device_id']);
    });

    test('reads MachineGuid from reg query output', () {
      const out =
          '\r\nHKEY_LOCAL_MACHINE\\SOFTWARE\\Microsoft\\Cryptography\r\n'
          '    MachineGuid    REG_SZ    3f2504e0-4f89-11d3-9a0c-0305e82c3301\r\n\r\n';
      expect(parseMachineGuid(out), '3f2504e0-4f89-11d3-9a0c-0305e82c3301');
      expect(parseMachineGuid('ERROR: The system was unable to find the specified registry key or value.'), isNull);
    });

    test('reads IOPlatformUUID from ioreg output', () {
      const out =
          '+-o J316sAP  <class IOPlatformExpertDevice, id 0x100000243, registered, matched, active, busy 0 (0 ms), retain 39>\n'
          '    {\n'
          '      "IOPlatformSerialNumber" = "C02XXXXXXXXX"\n'
          '      "IOPlatformUUID" = "8D3B5B9C-6E1A-4E37-9C1F-2B7A1D2E3F40"\n'
          '    }\n';
      expect(parseIoPlatformUuid(out), '8D3B5B9C-6E1A-4E37-9C1F-2B7A1D2E3F40');
      expect(parseIoPlatformUuid(''), isNull);
    });

    test('falls back to the D-Bus machine id', () async {
      final dir = await Directory.systemTemp.createTemp('cirrus-machine-id');
      addTearDown(() => dir.delete(recursive: true));
      final etc = File('${dir.path}/etc-machine-id');
      final dbus = File('${dir.path}/dbus-machine-id')..writeAsStringSync('dbus-id\n');
      final paths = [etc.path, dbus.path];
      expect(await readLinuxMachineId(paths: paths), 'dbus-id');
      etc.writeAsStringSync('  \n');
      expect(await readLinuxMachineId(paths: paths), 'dbus-id');
      etc.writeAsStringSync('etc-id\n');
      expect(await readLinuxMachineId(paths: paths), 'etc-id');
      expect(await readLinuxMachineId(paths: ['${dir.path}/missing']), isNull);
    });
  });

  group('licence keys', () {
    test('normalise like the server', () {
      for (final input in [
        linuxKey,
        '  cirrus-7k3qd-m2xrt-9vb4n-hj6wp \n',
        '7K3QDM2XRT9VB4NHJ6WP',
        'CIRRUS7K3QDM2XRT9VB4NHJ6WP',
        '7k3qd-m2xrt-9vb4n-hj6wp',
        'CIRRUS-7K3QD M2XRT-9VB4N-HJ6WP',
        'cirrus 7k3qd m2xrt 9vb4n\thj6wp',
      ]) {
        expect(normalizeLicenseKey(input), linuxKey, reason: input);
      }
      expect(normalizeLicenseKey('cirrus-oOiIl-LlL00-ABCDE-FGHJK'), 'CIRRUS-00111-11100-ABCDE-FGHJK');
    });

    test('reject anything that cannot be a key', () {
      for (final input in [
        '',
        'CIRRUS',
        'CIRRUS-7K3QD-M2XRT-9VB4N',
        '$linuxKey-AAAAA',
        'CIRRUS-7K3QD-M2XRT-9VB4N-HJ6WU',
        'CIRRUS_7K3QD_M2XRT_9VB4N_HJ6WP',
      ]) {
        expect(normalizeLicenseKey(input), isNull, reason: input);
      }
    });

    test('are masked for display', () {
      expect(maskLicenseKey(linuxKey), 'CIRRUS-XXXXX-…-HJ6WP');
    });
  });

  test('config keeps the server and needs a 32-byte public key', () {
    expect(testLicenseConfig.server, 'https://licence.test');
    expect(testLicenseConfig.canActivate, isTrue);
    expect(
      testLicenseConfig.buyUri(LicensePlatform.windows).toString(),
      'https://licence.test/buy?product=cirrus-windows',
    );
    expect(testLicenseConfig.manageUri.toString(), 'https://licence.test/license');
    final none = LicenseConfig.parse();
    expect(none.server, LicenseConfig.defaultServer);
    expect(none.canActivate, isFalse);
    expect(LicenseConfig.parse(publicKey: 'not base64!').canActivate, isFalse);
    expect(LicenseConfig.parse(publicKey: base64.encode(List.filled(16, 1))).canActivate, isFalse);
  });

  group('licence store', () {
    late Directory dir;

    setUp(() async {
      dir = await Directory.systemTemp.createTemp('cirrus-license-store');
      addTearDown(() => dir.delete(recursive: true));
    });

    test('keeps the key and token in secure storage', () async {
      FlutterSecureStorage.setMockInitialValues({});
      final store = LicenseStore(fallbackDir: () async => dir);
      expect(await store.load(), isNull);
      await store.save(const StoredLicense(key: linuxKey, token: 'payload.signature'));
      final raw = await const FlutterSecureStorage().read(key: 'cirrus.license.v1');
      expect(jsonDecode(raw!), {'key': linuxKey, 'token': 'payload.signature'});
      expect(store.usingFallback, isFalse);
      expect((await LicenseStore(fallbackDir: () async => dir).load())?.token, 'payload.signature');
      await store.clear();
      expect(await store.load(), isNull);
    });

    test('falls back to a private file without a keychain', () async {
      final store = LicenseStore(storage: const _NoKeychain(), fallbackDir: () async => dir);
      expect(await store.load(), isNull);
      expect(store.usingFallback, isTrue);
      await store.save(const StoredLicense(key: linuxKey, token: 'payload.signature'));
      final file = File('${dir.path}/license.json');
      expect(jsonDecode(file.readAsStringSync()), {'key': linuxKey, 'token': 'payload.signature'});
      if (!Platform.isWindows) expect(file.statSync().mode & 0x1ff, 0x180); // 0600
      expect((await store.load())?.key, linuxKey);
      await store.clear();
      expect(file.existsSync(), isFalse);
    });
  });

  group('licence controller', () {
    late FakeLicenseServer server;
    late MemoryLicenseStore store;

    setUp(() {
      mockAppVersion();
      SharedPreferences.setMockInitialValues({});
      server = FakeLicenseServer()
        ..licences[linuxKey] = FakeLicence(platform: 'linux')
        ..licences[windowsKey] = FakeLicence(platform: 'windows');
      store = MemoryLicenseStore();
    });

    /// A licence build's container, with the stored activation loaded.
    Future<ProviderContainer> start({DeviceIdentity? device, LicenseConfig? config}) async {
      final sp = await SharedPreferences.getInstance();
      final c = ProviderContainer(
        overrides: [
          sharedPrefsProvider.overrideWithValue(sp),
          ...licenseOverrides(server, store: store, device: device, config: config),
        ],
      );
      addTearDown(c.dispose);
      await until(() => !c.read(licenseProvider).loading);
      return c;
    }

    Future<int?> lastValidated() async =>
        (await SharedPreferences.getInstance()).getInt(LicenseController.lastValidatedKey);

    Future<void> setLastValidated(Duration ago) async => (await SharedPreferences.getInstance()).setInt(
      LicenseController.lastValidatedKey,
      DateTime.now().subtract(ago).millisecondsSinceEpoch,
    );

    test('activates, persists and reloads the activation', () async {
      final c = await start();
      expect(c.read(licenseProvider).isActive, isFalse);
      expect(await c.read(licenseProvider.notifier).activate(' cirrus-7k3qd-m2xrt-9vb4n-hj6wp\n'), isTrue);
      final s = c.read(licenseProvider);
      expect(s.busy, isFalse);
      expect(s.error, isNull);
      expect(s.active?.key, linuxKey);
      expect(s.active?.maskedKey, 'CIRRUS-XXXXX-…-HJ6WP');
      expect(s.active?.payload.owner, 'q***@example.com');
      expect(s.active?.payload.platform, 'linux');
      expect(server.callsTo('activate').single.body, {
        'license_key': linuxKey,
        'device_id': vectorDevice.id,
        'device_name': 'test-host',
        'platform': 'linux',
        'app_version': '1.0.0',
      });
      expect(server.licences[linuxKey]!.devices, {vectorDevice.id: 'test-host'});
      expect(store.stored?.key, linuxKey);
      expect(store.stored?.token, s.active?.token);
      expect(await lastValidated(), isNotNull);

      // The next start verifies the stored token and, just activated, skips the check.
      final again = await start();
      expect(again.read(licenseProvider).active?.key, linuxKey);
      await Future<void>.delayed(const Duration(milliseconds: 20));
      expect(server.callsTo('validate'), isEmpty);
    });

    test('refuses malformed and unknown keys', () async {
      final c = await start();
      final ctl = c.read(licenseProvider.notifier);
      expect(await ctl.activate('CIRRUS-1234'), isFalse);
      expect(c.read(licenseProvider).error?.code, LicenseError.invalidKey);
      expect(server.calls, isEmpty);
      expect(await ctl.activate('CIRRUS-ZZZZZ-ZZZZZ-ZZZZZ-ZZZZZ'), isFalse);
      final error = c.read(licenseProvider).error!;
      expect(error.code, LicenseError.invalidKey);
      expect(error.statusCode, 404);
      expect(c.read(licenseProvider).isActive, isFalse);
      expect(store.stored, isNull);
    });

    test('reports keys for another platform and revoked licences', () async {
      final c = await start();
      final ctl = c.read(licenseProvider.notifier);
      expect(await ctl.activate(windowsKey), isFalse);
      expect(c.read(licenseProvider).error?.code, LicenseError.wrongPlatform);
      server.licences[linuxKey]!.revoked = true;
      expect(await ctl.activate(linuxKey), isFalse);
      expect(c.read(licenseProvider).error?.code, LicenseError.revoked);
      expect(c.read(licenseProvider).error?.message, '错误：revoked');
    });

    test('the activation limit lists the devices using the licence', () async {
      server.licences[linuxKey]!.devices['elsewhere'] = "Felix's ThinkPad";
      final c = await start();
      expect(await c.read(licenseProvider.notifier).activate(linuxKey), isFalse);
      final error = c.read(licenseProvider).error!;
      expect(error.code, LicenseError.activationLimit);
      expect(error.statusCode, 409);
      expect(error.devices.single.name, "Felix's ThinkPad");
      expect(error.devices.single.activatedAt, DateTime.utc(2026));
      expect(c.read(licenseProvider).isActive, isFalse);
    });

    test('a network error leaves the device unactivated', () async {
      server.offline = true;
      final c = await start();
      expect(await c.read(licenseProvider.notifier).activate(linuxKey), isFalse);
      final s = c.read(licenseProvider);
      expect(s.error?.code, LicenseError.network);
      expect(s.busy, isFalse);
      expect(s.isActive, isFalse);
      expect(store.stored, isNull);
    });

    test('deactivates and frees the device, but not while offline', () async {
      final c = await start();
      final ctl = c.read(licenseProvider.notifier);
      await ctl.activate(linuxKey);
      server.offline = true;
      expect(await ctl.deactivate(), isFalse);
      expect(c.read(licenseProvider).error?.code, LicenseError.network);
      expect(c.read(licenseProvider).isActive, isTrue);
      expect(store.stored, isNotNull);
      server.offline = false;
      expect(await ctl.deactivate(), isTrue);
      expect(c.read(licenseProvider).isActive, isFalse);
      expect(c.read(licenseProvider).error, isNull);
      expect(store.stored, isNull);
      expect(server.licences[linuxKey]!.devices, isEmpty);
      expect(server.callsTo('deactivate').single.body, {'license_key': linuxKey, 'device_id': vectorDevice.id});
      expect(await lastValidated(), isNull);
    });

    test('validation drops a revoked licence', () async {
      await (await start()).read(licenseProvider.notifier).activate(linuxKey);
      server.licences[linuxKey]!.revoked = true;
      await setLastValidated(const Duration(days: 8));
      final c = await start();
      await until(() => c.read(licenseProvider).error != null);
      expect(c.read(licenseProvider).error?.code, LicenseError.revoked);
      expect(c.read(licenseProvider).isActive, isFalse);
      expect(c.read(proProvider).hasPro, isFalse);
      expect(store.stored, isNull);
      expect(server.callsTo('validate').single.body, {'license_key': linuxKey, 'device_id': vectorDevice.id});
    });

    test('validation drops an activation released on the website', () async {
      final c = await start();
      await c.read(licenseProvider.notifier).activate(linuxKey);
      server.licences[linuxKey]!.devices.clear();
      await c.read(licenseProvider.notifier).validate(force: true);
      expect(c.read(licenseProvider).error?.code, LicenseError.notActivated);
      expect(c.read(licenseProvider).isActive, isFalse);
      expect(store.stored, isNull);
    });

    test('validation keeps the activation when offline', () async {
      await (await start()).read(licenseProvider.notifier).activate(linuxKey);
      await setLastValidated(const Duration(days: 30));
      final before = await lastValidated();
      server.offline = true;
      final c = await start();
      await c.read(licenseProvider.notifier).validate();
      expect(c.read(licenseProvider).isActive, isTrue);
      expect(c.read(licenseProvider).error, isNull);
      expect(store.stored, isNotNull);
      // Still due, so the next start tries again.
      expect(await lastValidated(), before);
    });

    test('validation runs at most once every 7 days', () async {
      final c = await start();
      final ctl = c.read(licenseProvider.notifier);
      await ctl.activate(linuxKey);
      await ctl.validate();
      expect(server.callsTo('validate'), isEmpty);
      await setLastValidated(const Duration(days: 6, hours: 23));
      await ctl.validate();
      expect(server.callsTo('validate'), isEmpty);
      await setLastValidated(const Duration(days: 7, hours: 1));
      await ctl.validate();
      expect(server.callsTo('validate'), hasLength(1));
      expect(DateTime.now().millisecondsSinceEpoch - (await lastValidated())!, lessThan(60000));
      await ctl.validate();
      expect(server.callsTo('validate'), hasLength(1));
      await ctl.validate(force: true);
      expect(server.callsTo('validate'), hasLength(2));
      expect(c.read(licenseProvider).isActive, isTrue);
    });

    test('a stored activation for another device is dropped on load', () async {
      await (await start()).read(licenseProvider.notifier).activate(linuxKey);
      final c = await start(device: DeviceIdentity.fromRaw('another machine', name: 'clone'));
      expect(c.read(licenseProvider).isActive, isFalse);
      expect(store.stored, isNull);
    });

    test('without a public key, activation is disabled', () async {
      final c = await start(config: LicenseConfig.parse(server: 'https://licence.test'));
      expect(c.read(licenseProvider).error?.code, LicenseError.notConfigured);
      expect(await c.read(licenseProvider.notifier).activate(linuxKey), isFalse);
      expect(c.read(licenseProvider).error?.code, LicenseError.notConfigured);
      expect(server.calls, isEmpty);
    });

    test('Pro follows the activation in licence builds', () async {
      final c = await start();
      expect(c.read(proProvider).enforced, isTrue);
      expect(c.read(proProvider).hasPro, isFalse);
      await c.read(licenseProvider.notifier).activate(linuxKey);
      expect(c.read(proProvider).hasPro, isTrue);
      await c.read(licenseProvider.notifier).deactivate();
      expect(c.read(proProvider).hasPro, isFalse);
    });
  });
}
