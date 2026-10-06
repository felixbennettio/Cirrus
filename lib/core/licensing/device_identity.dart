import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

/// This device as the licence server knows it.
@immutable
class DeviceIdentity {
  const DeviceIdentity({required this.id, required this.name});

  DeviceIdentity.fromRaw(String raw, {required String name}) : this(id: deviceIdFor(raw), name: name);

  /// Opaque: the server never sees the raw machine id.
  final String id;

  /// Host name, or `manufacturer model` on Android. For display only.
  final String name;
}

/// Lowercase hex `sha256("cirrus-device:" + raw)`, with [raw] trimmed.
String deviceIdFor(String raw) => sha256.convert(utf8.encode('cirrus-device:${raw.trim()}')).toString();

/// Reads the [DeviceIdentity]. An interface so tests can stand in for the
/// registry, `/etc/machine-id` and Android.
abstract interface class DeviceIdentitySource {
  Future<DeviceIdentity> read();
}

/// [DeviceIdentitySource] backed by the operating system:
///
/// - Windows: `MachineGuid` under `HKLM\SOFTWARE\Microsoft\Cryptography`
/// - Linux: `/etc/machine-id`, falling back to `/var/lib/dbus/machine-id`
/// - Android: `Settings.Secure.ANDROID_ID`, through [channel]
class PlatformDeviceIdentity implements DeviceIdentitySource {
  PlatformDeviceIdentity();

  /// Implemented in `MainActivity.kt`.
  static const channel = MethodChannel('io.felixbennett.cirrus/device');

  /// Only a successful read is kept; a failed one is tried again.
  DeviceIdentity? _cached;

  @override
  Future<DeviceIdentity> read() async => _cached ??= await _read();

  Future<DeviceIdentity> _read() async {
    final String? raw;
    final String name;
    if (Platform.isWindows) {
      // Flutter's Windows runner is a 64-bit process, so this reads the
      // 64-bit registry view where MachineGuid lives.
      final res = await Process.run('reg', ['query', r'HKLM\SOFTWARE\Microsoft\Cryptography', '/v', 'MachineGuid']);
      raw = res.exitCode == 0 ? parseMachineGuid('${res.stdout}') : null;
      name = Platform.localHostname;
    } else if (Platform.isLinux) {
      raw = await readLinuxMachineId();
      name = Platform.localHostname;
    } else if (Platform.isAndroid) {
      raw = await channel.invokeMethod<String>('androidId');
      name = await channel.invokeMethod<String>('deviceName') ?? 'Android';
    } else {
      throw UnsupportedError('Licences are not sold for ${Platform.operatingSystem}.');
    }
    if (raw == null || raw.trim().isEmpty) throw StateError('No machine id found on this device.');
    return DeviceIdentity.fromRaw(raw, name: name.trim());
  }
}

/// The MachineGuid value in the output of
/// `reg query HKLM\SOFTWARE\Microsoft\Cryptography /v MachineGuid`.
String? parseMachineGuid(String output) =>
    RegExp(r'^\s*MachineGuid\s+REG_SZ\s+(\S+)\s*$', multiLine: true).firstMatch(output)?.group(1);

const linuxMachineIdPaths = ['/etc/machine-id', '/var/lib/dbus/machine-id'];

/// The first non-empty machine id among [paths].
Future<String?> readLinuxMachineId({List<String> paths = linuxMachineIdPaths}) async {
  for (final path in paths) {
    try {
      final id = (await File(path).readAsString()).trim();
      if (id.isNotEmpty) return id;
    } on FileSystemException {
      // Missing or unreadable: try the next one.
    }
  }
  return null;
}

final deviceIdentityProvider = Provider<DeviceIdentitySource>((ref) => PlatformDeviceIdentity());
