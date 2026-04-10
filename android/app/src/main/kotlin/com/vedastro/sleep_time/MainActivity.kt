package com.vedastro.sleep_time

import android.app.admin.DevicePolicyManager
import android.content.ComponentName
import android.content.Context
import android.content.Intent
import android.os.Bundle
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel

class MainActivity : FlutterActivity() {
    private val CHANNEL = "com.vedastro.sleep_time/lockdown"
    private lateinit var devicePolicyManager: DevicePolicyManager
    private lateinit var adminComponent: ComponentName

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)

        devicePolicyManager = getSystemService(Context.DEVICE_POLICY_SERVICE) as DevicePolicyManager
        adminComponent = ComponentName(this, SleepDeviceAdminReceiver::class.java)

        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, CHANNEL).setMethodCallHandler { call, result ->
            when (call.method) {
                "requestDeviceAdmin" -> {
                    val intent = Intent(DevicePolicyManager.ACTION_ADD_DEVICE_ADMIN).apply {
                        putExtra(DevicePolicyManager.EXTRA_DEVICE_ADMIN, adminComponent)
                        putExtra(
                            DevicePolicyManager.EXTRA_ADD_EXPLANATION,
                            "Sleep Time needs device admin to lock your screen during bedtime."
                        )
                    }
                    startActivityForResult(intent, 1)
                    result.success(true)
                }
                "hasDeviceAdmin" -> {
                    result.success(devicePolicyManager.isAdminActive(adminComponent))
                }
                "activateLockdown" -> {
                    try {
                        // Lock the screen
                        if (devicePolicyManager.isAdminActive(adminComponent)) {
                            devicePolicyManager.lockNow()
                        }
                        // Start screen pinning (kiosk mode)
                        startLockTask()
                        result.success(true)
                    } catch (e: Exception) {
                        result.error("LOCKDOWN_FAILED", e.message, null)
                    }
                }
                "deactivateLockdown" -> {
                    try {
                        stopLockTask()
                        result.success(true)
                    } catch (e: Exception) {
                        result.error("UNLOCK_FAILED", e.message, null)
                    }
                }
                "startScreenPinning" -> {
                    try {
                        startLockTask()
                        result.success(true)
                    } catch (e: Exception) {
                        result.error("PIN_FAILED", e.message, null)
                    }
                }
                "grantExtension" -> {
                    try {
                        stopLockTask()
                        result.success(true)
                    } catch (e: Exception) {
                        result.error("GRANT_FAILED", e.message, null)
                    }
                }
                "openApp" -> {
                    val packageName = call.argument<String>("packageName")
                    if (packageName != null) {
                        val launchIntent = packageManager.getLaunchIntentForPackage(packageName)
                        if (launchIntent != null) {
                            startActivity(launchIntent)
                            result.success(true)
                        } else {
                            result.success(false)
                        }
                    } else {
                        result.error("INVALID_PACKAGE", "Package name required", null)
                    }
                }
                else -> result.notImplemented()
            }
        }
    }
}
