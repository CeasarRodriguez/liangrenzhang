package com.k1ngmew.liangrenzhang

import android.Manifest
import android.app.NotificationManager
import android.content.Intent
import android.content.pm.PackageManager
import android.net.Uri
import android.os.Build
import android.os.PowerManager
import android.provider.Settings
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel

class MainActivity : FlutterActivity() {
    private var pendingPermissionResult: MethodChannel.Result? = null

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, "couple_ledger/native")
            .setMethodCallHandler { call, result ->
                when (call.method) {
                    "platform" -> result.success("android")
                    "filesDir" -> result.success(filesDir.absolutePath)
                    "appVersion" -> result.success(appVersion())
                    "notificationsEnabled" -> result.success(notificationsEnabled())
                    "requestNotificationPermission" -> requestNotificationPermission(result)
                    "startAlertService" -> {
                        AlertService.configure(
                            this,
                            baseUrl = call.argument<String>("baseUrl") ?: "",
                            token = call.argument<String>("token") ?: "",
                            userId = call.argument<String>("userId") ?: "",
                            caPem = call.argument<String>("caPem") ?: "",
                        )
                        AlertService.start(this)
                        result.success(null)
                    }
                    "stopAlertService" -> {
                        AlertService.disable(this)
                        result.success(null)
                    }
                    "isIgnoringBatteryOptimizations" -> {
                        val pm = getSystemService(PowerManager::class.java)
                        result.success(pm.isIgnoringBatteryOptimizations(packageName))
                    }
                    "requestIgnoreBatteryOptimizations" -> {
                        startSafely(
                            Intent(Settings.ACTION_REQUEST_IGNORE_BATTERY_OPTIMIZATIONS, Uri.parse("package:$packageName")),
                            Intent(Settings.ACTION_IGNORE_BATTERY_OPTIMIZATION_SETTINGS),
                        )
                        result.success(null)
                    }
                    "openAppSettings" -> {
                        startSafely(Intent(Settings.ACTION_APPLICATION_DETAILS_SETTINGS, Uri.parse("package:$packageName")))
                        result.success(null)
                    }
                    else -> result.notImplemented()
                }
            }
    }

    private fun appVersion(): String =
        try {
            packageManager.getPackageInfo(packageName, 0).versionName ?: ""
        } catch (e: PackageManager.NameNotFoundException) {
            ""
        }

    private fun notificationsEnabled(): Boolean =
        getSystemService(NotificationManager::class.java).areNotificationsEnabled()

    private fun requestNotificationPermission(result: MethodChannel.Result) {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.TIRAMISU || notificationsEnabled()) {
            if (!notificationsEnabled()) {
                startSafely(Intent(Settings.ACTION_APP_NOTIFICATION_SETTINGS).putExtra(Settings.EXTRA_APP_PACKAGE, packageName))
            }
            result.success(notificationsEnabled())
            return
        }
        pendingPermissionResult = result
        requestPermissions(arrayOf(Manifest.permission.POST_NOTIFICATIONS), REQUEST_NOTIFICATIONS)
    }

    override fun onRequestPermissionsResult(requestCode: Int, permissions: Array<out String>, grantResults: IntArray) {
        super.onRequestPermissionsResult(requestCode, permissions, grantResults)
        if (requestCode == REQUEST_NOTIFICATIONS) {
            pendingPermissionResult?.success(notificationsEnabled())
            pendingPermissionResult = null
        }
    }

    private fun startSafely(vararg intents: Intent) {
        for (intent in intents) {
            try {
                startActivity(intent)
                return
            } catch (e: Exception) {
                // try the next, more generic settings screen
            }
        }
    }

    companion object {
        private const val REQUEST_NOTIFICATIONS = 1001
    }
}
