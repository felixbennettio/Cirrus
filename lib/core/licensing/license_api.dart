import 'dart:convert';

import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../util/format.dart';
import 'license_config.dart';

/// Error codes: the licence server's (`docs/licensing.md`) and the ones
/// raised in the app.
abstract final class LicenseError {
  static const invalidKey = 'invalid_key';
  static const wrongPlatform = 'wrong_platform';
  static const revoked = 'revoked';
  static const activationLimit = 'activation_limit';

  /// `/validate` reported that this device is no longer activated.
  static const notActivated = 'not_activated';

  static const network = 'network_error';
  static const badResponse = 'bad_response';

  /// The server's activation token did not verify.
  static const invalidToken = 'invalid_token';
  static const deviceUnavailable = 'device_unavailable';

  /// The build has no licence public key.
  static const notConfigured = 'not_configured';

  /// Anything else, e.g. the activation could not be saved.
  static const unexpected = 'unexpected';
}

/// A device holding one of a licence's activations.
@immutable
class LicenseDevice {
  const LicenseDevice({required this.name, this.activatedAt});

  factory LicenseDevice.fromJson(Map<String, dynamic> j) =>
      LicenseDevice(name: '${j['name'] ?? ''}', activatedAt: parseDate(j['activated_at']));

  final String name;
  final DateTime? activatedAt;
}

/// A failed licence operation. [code] is one of [LicenseError] or another
/// code sent by the server.
class LicenseException implements Exception {
  const LicenseException(this.code, {this.message = '', this.statusCode, this.devices = const []});

  final String code;

  /// The server's explanation (in Chinese), or details of a local failure.
  final String message;
  final int? statusCode;

  /// The devices using up the licence, for [LicenseError.activationLimit].
  final List<LicenseDevice> devices;

  @override
  String toString() => message.isEmpty ? code : '$code: $message';
}

/// A successful activation.
@immutable
class LicenseActivation {
  const LicenseActivation({
    required this.token,
    required this.product,
    required this.platform,
    this.maxDevices,
    this.devicesUsed,
  });

  /// The signed activation token for this device.
  final String token;
  final String product;
  final String platform;
  final int? maxDevices;
  final int? devicesUsed;
}

/// What `/validate` says about this device's activation.
enum LicenseCheck { active, notActivated, revoked }

/// Talks to the licence server (`/api/v1`).
class LicenseApi {
  LicenseApi(this.baseUrl, {Dio? dio})
    : _dio =
          dio ??
          Dio(BaseOptions(connectTimeout: const Duration(seconds: 15), receiveTimeout: const Duration(seconds: 20)));

  final String baseUrl;
  final Dio _dio;

  Future<LicenseActivation> activate({
    required String key,
    required String deviceId,
    required String deviceName,
    required LicensePlatform platform,
    required String appVersion,
  }) async {
    final json = await _post('activate', {
      'license_key': key,
      'device_id': deviceId,
      'device_name': deviceName,
      'platform': platform.name,
      'app_version': appVersion,
    });
    final token = json['activation'];
    if (token is! String || token.isEmpty) {
      throw const LicenseException(LicenseError.badResponse, message: 'The activation response has no token.');
    }
    final license = json['license'] is Map ? Map<String, dynamic>.from(json['license'] as Map) : const {};
    return LicenseActivation(
      token: token,
      product: '${license['product'] ?? ''}',
      platform: '${license['platform'] ?? ''}',
      maxDevices: _int(license['max_devices']),
      devicesUsed: _int(license['devices_used']),
    );
  }

  /// Frees this device's activation. Succeeds also when the device was not
  /// activated.
  Future<void> deactivate({required String key, required String deviceId}) =>
      _post('deactivate', {'license_key': key, 'device_id': deviceId});

  Future<LicenseCheck> validate({required String key, required String deviceId}) async {
    final json = await _post('validate', {'license_key': key, 'device_id': deviceId});
    return switch (json['status']) {
      'active' => LicenseCheck.active,
      'not_activated' => LicenseCheck.notActivated,
      'revoked' => LicenseCheck.revoked,
      final s => throw LicenseException(LicenseError.badResponse, message: 'Unknown licence status: $s'),
    };
  }

  Future<Map<String, dynamic>> _post(String path, Map<String, Object?> body) async {
    final Response<String> res;
    try {
      res = await _dio.post<String>(
        '$baseUrl/api/v1/$path',
        data: body,
        options: Options(
          contentType: Headers.jsonContentType,
          responseType: ResponseType.plain,
          headers: {'Accept': 'application/json'},
          // Errors arrive as 4xx JSON bodies; parse them below.
          validateStatus: (_) => true,
        ),
      );
    } on DioException catch (e) {
      throw LicenseException(LicenseError.network, message: e.message ?? e.error?.toString() ?? e.type.name);
    }
    final status = res.statusCode ?? 0;
    Map<String, dynamic> json;
    try {
      json = Map<String, dynamic>.from(jsonDecode(res.data ?? '') as Map);
    } catch (_) {
      json = const {};
    }
    if (status < 200 || status >= 300) {
      final devices = json['devices'];
      throw LicenseException(
        switch (json['error']) {
          final String code when code.isNotEmpty => code,
          _ => 'http_$status',
        },
        message: '${json['message'] ?? ''}',
        statusCode: status,
        devices: devices is List
            ? devices.whereType<Map>().map((d) => LicenseDevice.fromJson(Map<String, dynamic>.from(d))).toList()
            : const [],
      );
    }
    if (json.isEmpty) {
      throw LicenseException(
        LicenseError.badResponse,
        message: 'Unexpected response from the licence server.',
        statusCode: status,
      );
    }
    return json;
  }

  static int? _int(Object? v) => v is num ? v.toInt() : null;
}

final licenseApiProvider = Provider<LicenseApi>((ref) => LicenseApi(ref.watch(licenseConfigProvider).server));
