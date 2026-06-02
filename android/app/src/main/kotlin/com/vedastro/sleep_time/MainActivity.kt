package com.vedastro.sleep_time

import android.app.AlarmManager
import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.content.IntentFilter
import android.net.Uri
import android.os.Build
import android.os.PowerManager
import android.provider.Settings
import androidx.core.app.NotificationManagerCompat
import androidx.localbroadcastmanager.content.LocalBroadcastManager
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.EventChannel
import io.flutter.plugin.common.MethodChannel

/**
 * Bridges the Play-compliant background guardian (M4) to Dart.
 *
 * MethodChannel `com.vedastro.sleep_time/lockdown`:
 *   ping, startGuardian, stopGuardian, getPermissionStatus, setSchedule,
 *   requestExactAlarm, requestNotifications, requestBatteryExemption,
 *   requestOverlay (M5 stub), requestUsageAccess (M5 stub), allowApp (M5 stub).
 *
 * EventChannel `com.vedastro.sleep_time/lockdown_events` streams maps of
 *   {state: String, grantExpiresAt: Long, degraded: Boolean}
 * forwarded from [SleepGuardianService] via LocalBroadcastManager.
 *
 * All Device Admin / lockTask / screen-pinning logic from the M1 stub has been
 * removed (Play-incompatible).
 */
class MainActivity : FlutterActivity() {
    private val channelName = "com.vedastro.sleep_time/lockdown"
    private val eventChannelName = "com.vedastro.sleep_time/lockdown_events"

    private var eventSink: EventChannel.EventSink? = null
    private var stateReceiver: BroadcastReceiver? = null

    private val notificationsRequestCode = 9001

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)

        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, channelName)
            .setMethodCallHandler { call, result ->
                when (call.method) {
                    "ping" -> result.success(true)

                    "startGuardian" -> {
                        SleepGuardianService.start(this)
                        result.success(true)
                    }

                    "stopGuardian" -> {
                        SleepGuardianService.stop(this)
                        result.success(true)
                    }

                    "setSchedule" -> {
                        // Dart already persisted the schedule to SharedPreferences;
                        // we just re-derive the alarms from it.
                        SleepAlarmScheduler.rescheduleAll(this)
                        result.success(true)
                    }

                    "getPermissionStatus" -> result.success(permissionStatus())

                    "requestExactAlarm" -> {
                        requestExactAlarm()
                        result.success(true)
                    }

                    "requestNotifications" -> {
                        requestNotifications()
                        result.success(true)
                    }

                    "requestBatteryExemption" -> {
                        requestBatteryExemption()
                        result.success(true)
                    }

                    // M5 fills these in (overlay / usage-access / per-app allow).
                    "requestOverlay" -> result.success(false)
                    "requestUsageAccess" -> result.success(false)
                    "allowApp" -> result.success(false)

                    else -> result.notImplemented()
                }
            }

        EventChannel(flutterEngine.dartExecutor.binaryMessenger, eventChannelName)
            .setStreamHandler(object : EventChannel.StreamHandler {
                override fun onListen(arguments: Any?, events: EventChannel.EventSink?) {
                    eventSink = events
                    registerStateReceiver()
                }

                override fun onCancel(arguments: Any?) {
                    unregisterStateReceiver()
                    eventSink = null
                }
            })
    }

    private fun registerStateReceiver() {
        if (stateReceiver != null) return
        val receiver = object : BroadcastReceiver() {
            override fun onReceive(context: Context?, intent: Intent?) {
                if (intent == null) return
                val map = mapOf(
                    "state" to (intent.getStringExtra(SleepGuardianService.EXTRA_STATE)
                        ?: SleepGuardianService.STATE_INACTIVE),
                    "grantExpiresAt" to intent.getLongExtra(
                        SleepGuardianService.EXTRA_GRANT_EXPIRES_AT, 0L),
                    "degraded" to intent.getBooleanExtra(
                        SleepGuardianService.EXTRA_DEGRADED, false),
                )
                eventSink?.success(map)
            }
        }
        stateReceiver = receiver
        LocalBroadcastManager.getInstance(this).registerReceiver(
            receiver,
            IntentFilter(SleepGuardianService.BROADCAST_STATE),
        )
    }

    private fun unregisterStateReceiver() {
        stateReceiver?.let {
            LocalBroadcastManager.getInstance(this).unregisterReceiver(it)
        }
        stateReceiver = null
    }

    override fun onDestroy() {
        unregisterStateReceiver()
        super.onDestroy()
    }

    private fun permissionStatus(): Map<String, Boolean> {
        val notifications = NotificationManagerCompat.from(this).areNotificationsEnabled()

        val exactAlarm = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.S) {
            val am = getSystemService(Context.ALARM_SERVICE) as AlarmManager
            am.canScheduleExactAlarms()
        } else {
            true
        }

        val powerManager = getSystemService(Context.POWER_SERVICE) as PowerManager
        val batteryExemption = powerManager.isIgnoringBatteryOptimizations(packageName)

        return mapOf(
            "notifications" to notifications,
            "exactAlarm" to exactAlarm,
            "batteryExemption" to batteryExemption,
            // M5 placeholders.
            "overlay" to false,
            "accessibility" to false,
            "usageAccess" to false,
        )
    }

    private fun requestExactAlarm() {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.S) return
        val intent = Intent(Settings.ACTION_REQUEST_SCHEDULE_EXACT_ALARM).apply {
            data = Uri.parse("package:$packageName")
            addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
        }
        try {
            startActivity(intent)
        } catch (_: Exception) {
            // Some OEMs lack the dedicated screen; fall back to app settings.
            openAppSettings()
        }
    }

    private fun requestNotifications() {
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) {
            requestPermissions(
                arrayOf(android.Manifest.permission.POST_NOTIFICATIONS),
                notificationsRequestCode,
            )
        }
    }

    private fun requestBatteryExemption() {
        val intent = Intent(Settings.ACTION_REQUEST_IGNORE_BATTERY_OPTIMIZATIONS).apply {
            data = Uri.parse("package:$packageName")
            addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
        }
        try {
            startActivity(intent)
        } catch (_: Exception) {
            openAppSettings()
        }
    }

    private fun openAppSettings() {
        val intent = Intent(Settings.ACTION_APPLICATION_DETAILS_SETTINGS).apply {
            data = Uri.parse("package:$packageName")
            addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
        }
        try {
            startActivity(intent)
        } catch (_: Exception) {
        }
    }
}
