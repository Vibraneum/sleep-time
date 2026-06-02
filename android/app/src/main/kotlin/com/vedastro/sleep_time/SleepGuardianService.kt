package com.vedastro.sleep_time

import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.app.Service
import android.content.Context
import android.content.Intent
import android.content.pm.ServiceInfo
import android.os.Build
import android.os.IBinder
import androidx.localbroadcastmanager.content.LocalBroadcastManager

/**
 * The Play-compliant background bedtime guardian: a `specialUse` foreground
 * service that posts a persistent low-importance notification and re-evaluates
 * the schedule state whenever an alarm fires.
 *
 * It is **alarm-driven, not loop-driven** — there is no busy polling. Alarms
 * scheduled by [SleepAlarmScheduler] wake [AlarmReceiver], which asks this
 * service to re-evaluate and transition.
 *
 * ## Safe mode
 * When `flutter.simulate_lockdown` is true the guardian still posts its
 * notification (so the user can see it is alive) but **never escalates** — it
 * only broadcasts state for the Dart UI to mirror. M4 has no escalation beyond
 * the notification anyway (overlay/blocking is M5), so "escalation" here means
 * future M5 hooks; the seam is left explicit in [evaluate].
 *
 * ## Turn-off path
 * The persistent notification carries a "Turn off" action that sends
 * [ACTION_STOP], satisfying the FGS dismissability policy.
 */
class SleepGuardianService : Service() {

    companion object {
        const val ACTION_START = "com.vedastro.sleep_time.guardian.START"
        const val ACTION_STOP = "com.vedastro.sleep_time.guardian.STOP"
        const val ACTION_EVALUATE = "com.vedastro.sleep_time.guardian.EVALUATE"
        const val EXTRA_ALARM_ACTION = "alarm_action"

        // Broadcast to the MainActivity EventChannel bridge.
        const val BROADCAST_STATE = "com.vedastro.sleep_time.guardian.STATE"
        const val EXTRA_STATE = "state"
        const val EXTRA_GRANT_EXPIRES_AT = "grantExpiresAt"
        const val EXTRA_DEGRADED = "degraded"

        const val STATE_INACTIVE = "inactive"
        const val STATE_WIND_DOWN = "windDown"
        const val STATE_LOCKED = "locked"
        const val STATE_UNLOCKED = "unlocked"

        private const val CHANNEL_ID = "sleep_guardian"
        private const val NOTIFICATION_ID = 4201

        fun start(context: Context) {
            val intent = Intent(context, SleepGuardianService::class.java)
                .setAction(ACTION_START)
            startService(context, intent)
        }

        fun stop(context: Context) {
            val intent = Intent(context, SleepGuardianService::class.java)
                .setAction(ACTION_STOP)
            startService(context, intent)
        }

        /** Ask a (possibly already-running) service to re-evaluate state. */
        fun evaluate(context: Context, alarmAction: String?) {
            val intent = Intent(context, SleepGuardianService::class.java)
                .setAction(ACTION_EVALUATE)
                .putExtra(EXTRA_ALARM_ACTION, alarmAction)
            startService(context, intent)
        }

        private fun startService(context: Context, intent: Intent) {
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
                context.startForegroundService(intent)
            } else {
                context.startService(intent)
            }
        }
    }

    override fun onBind(intent: Intent?): IBinder? = null

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        when (intent?.action) {
            ACTION_STOP -> {
                stopGuardian()
                return START_NOT_STICKY
            }
            else -> {
                // Always promote to foreground within the 10s window first.
                ensureForeground()
                SleepAlarmScheduler.rescheduleAll(this)
                evaluate(intent?.getStringExtra(EXTRA_ALARM_ACTION))
            }
        }
        // START_STICKY: if the OS kills us, restart with a null intent and we
        // re-promote + re-evaluate from the current schedule.
        return START_STICKY
    }

    private fun ensureForeground() {
        createChannel()
        val notification = buildNotification(STATE_INACTIVE)
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.UPSIDE_DOWN_CAKE) {
            startForeground(
                NOTIFICATION_ID,
                notification,
                ServiceInfo.FOREGROUND_SERVICE_TYPE_SPECIAL_USE,
            )
        } else {
            startForeground(NOTIFICATION_ID, notification)
        }
    }

    /**
     * Re-derive the current state from the schedule and broadcast it. The
     * escalation seam for M5 (overlay / per-app blocking) lives here; in M4 we
     * only update the notification text and emit state.
     */
    private fun evaluate(alarmAction: String?) {
        val schedule = SleepScheduleStore.read(this)
        val simulating = SleepScheduleStore.isSimulating(this)
        val nowMinutes = Schedule.nowMinutes()

        val state = when {
            schedule.isInLockdownWindow(nowMinutes) -> STATE_LOCKED
            schedule.isInWindDownWindow(nowMinutes) -> STATE_WIND_DOWN
            else -> STATE_UNLOCKED
        }

        updateNotification(state)

        // M5 escalation seam: when !simulating && state == STATE_LOCKED, the
        // overlay / AccessibilityService blocking would arm here. In M4 there
        // is nothing to escalate; safe mode short-circuits future effects.
        if (!simulating && state == STATE_LOCKED) {
            // no-op in M4 (notification already posted) — M5 fills this in.
        }

        broadcastState(state)
    }

    private fun broadcastState(state: String) {
        val intent = Intent(BROADCAST_STATE).apply {
            putExtra(EXTRA_STATE, state)
            putExtra(EXTRA_GRANT_EXPIRES_AT, 0L)
            putExtra(EXTRA_DEGRADED, SleepAlarmScheduler.isDegraded(this@SleepGuardianService))
        }
        LocalBroadcastManager.getInstance(this).sendBroadcast(intent)
    }

    private fun stopGuardian() {
        SleepAlarmScheduler.cancelAll(this)
        broadcastState(STATE_INACTIVE)
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.N) {
            stopForeground(STOP_FOREGROUND_REMOVE)
        } else {
            @Suppress("DEPRECATION")
            stopForeground(true)
        }
        stopSelf()
    }

    private fun createChannel() {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.O) return
        val manager = getSystemService(NotificationManager::class.java)
        if (manager.getNotificationChannel(CHANNEL_ID) != null) return
        val channel = NotificationChannel(
            CHANNEL_ID,
            "Bedtime guardian",
            NotificationManager.IMPORTANCE_LOW,
        ).apply {
            description = "Keeps watch over your bedtime schedule in the background."
            setShowBadge(false)
        }
        manager.createNotificationChannel(channel)
    }

    private fun updateNotification(state: String) {
        val manager = getSystemService(NotificationManager::class.java)
        manager.notify(NOTIFICATION_ID, buildNotification(state))
    }

    private fun buildNotification(state: String): Notification {
        val openIntent = packageManager.getLaunchIntentForPackage(packageName)
        val contentPi = openIntent?.let {
            PendingIntent.getActivity(
                this, 0, it,
                PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE,
            )
        }

        val stopIntent = Intent(this, SleepGuardianService::class.java)
            .setAction(ACTION_STOP)
        val stopPi = PendingIntent.getService(
            this, 1, stopIntent,
            PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE,
        )

        val text = when (state) {
            STATE_LOCKED -> "Bedtime is active — it's time to sleep."
            STATE_WIND_DOWN -> "Wind down — bedtime is coming up."
            else -> "Watching your bedtime schedule."
        }

        val builder = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            Notification.Builder(this, CHANNEL_ID)
        } else {
            @Suppress("DEPRECATION")
            Notification.Builder(this)
        }

        builder
            .setContentTitle("Sleep Time is watching your bedtime")
            .setContentText(text)
            .setSmallIcon(android.R.drawable.ic_lock_idle_alarm)
            .setOngoing(true)
            .addAction(
                Notification.Action.Builder(null, "Turn off", stopPi).build(),
            )
        if (contentPi != null) builder.setContentIntent(contentPi)
        return builder.build()
    }
}
