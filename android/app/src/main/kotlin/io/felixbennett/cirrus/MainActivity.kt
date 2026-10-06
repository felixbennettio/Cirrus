package io.felixbennett.cirrus

import android.annotation.SuppressLint
import android.os.Build
import android.provider.Settings
import io.flutter.embedding.android.FlutterFragmentActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel

// FlutterFragmentActivity is required by local_auth (biometric app lock).
class MainActivity : FlutterFragmentActivity() {
    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        // Device identity for licence activation (lib/core/licensing/device_identity.dart).
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, "io.felixbennett.cirrus/device")
            .setMethodCallHandler { call, result ->
                when (call.method) {
                    "androidId" -> result.success(androidId())
                    "deviceName" -> result.success("${Build.MANUFACTURER} ${Build.MODEL}")
                    else -> result.notImplemented()
                }
            }
    }

    // Scoped to the app signing key, user and device since Android 8.
    @SuppressLint("HardwareIds")
    private fun androidId(): String? = Settings.Secure.getString(contentResolver, Settings.Secure.ANDROID_ID)
}
