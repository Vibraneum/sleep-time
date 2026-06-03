package com.vedastro.sleep_time

import android.app.AlarmManager
import android.app.PendingIntent
import android.content.Context
import android.content.Intent
import android.os.Build
import java.util.Calendar

/**
 * Schedules the three nightly transition alarms (WIND_DOWN / LOCK / UNLOCK)
 * via [AlarmManager].
 *
 * Exact alarms are guarded with [AlarmManager.canScheduleExactAlarms] on API
 * 31+. When the user has granted exact-alarm access we use
 * [AlarmManager.setExactAndAllowWhileIdle]; otherwise we degrade to the
 * idle-resilient inexact [AlarmManager.setAndAllowWhileIdle] (the OS may batch
 * it a few minutes late) and persist a `degraded` flag that Dart surfaces to
 * the user so they can grant the permission for on-the-minute accuracy.
 *
 * The scheduler is stateless beyond the persisted degraded flag — each alarm
 * carries an `EXTRA_ACTION` so the receiver knows which transition fired, and
 * receivers self-reschedule the next day's occurrence (+24h).
 */
object SleepAlarmScheduler {
    const val ACTION_ALARM = "com.vedastro.sleep_time.ALARM"
    const val EXTRA_ACTION = "action"

    const val ACTION_WIND_DOWN = "WIND_DOWN"
    const val ACTION_LOCK = "LOCK"
    const val ACTION_UNLOCK = "UNLOCK"

    private const val PREFS = "sleep_guardian_native"
    private const val KEY_DEGRADED = "exact_alarm_degraded"

    private const val REQ_WIND_DOWN = 1001
    private const val REQ_LOCK = 1002
    private const val REQ_UNLOCK = 1003

    /** Whether the most recent scheduling pass fell back to inexact alarms. */
    fun isDegraded(context: Context): Boolean =
        context.getSharedPreferences(PREFS, Context.MODE_PRIVATE)
            .getBoolean(KEY_DEGRADED, false)

    private fun setDegraded(context: Context, value: Boolean) {
        context.getSharedPreferences(PREFS, Context.MODE_PRIVATE)
            .edit().putBoolean(KEY_DEGRADED, value).apply()
    }

    private fun canExact(am: AlarmManager): Boolean =
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.S) am.canScheduleExactAlarms() else true

    /** Recompute and (re)arm all three alarms from the current schedule. */
    fun rescheduleAll(context: Context) {
        val schedule = SleepScheduleStore.read(context)
        val am = context.getSystemService(Context.ALARM_SERVICE) as AlarmManager
        val exact = canExact(am)
        setDegraded(context, !exact)

        scheduleNext(context, am, ACTION_WIND_DOWN, REQ_WIND_DOWN,
            schedule.windDown.hour, schedule.windDown.minute, exact)
        scheduleNext(context, am, ACTION_LOCK, REQ_LOCK,
            schedule.lockdown.hour, schedule.lockdown.minute, exact)
        scheduleNext(context, am, ACTION_UNLOCK, REQ_UNLOCK,
            schedule.unlock.hour, schedule.unlock.minute, exact)
    }

    /** Re-arm a single alarm for its next occurrence (used by the receiver). */
    fun rescheduleOne(context: Context, action: String) {
        val schedule = SleepScheduleStore.read(context)
        val am = context.getSystemService(Context.ALARM_SERVICE) as AlarmManager
        val exact = canExact(am)
        setDegraded(context, !exact)
        when (action) {
            ACTION_WIND_DOWN -> scheduleNext(context, am, ACTION_WIND_DOWN, REQ_WIND_DOWN,
                schedule.windDown.hour, schedule.windDown.minute, exact)
            ACTION_LOCK -> scheduleNext(context, am, ACTION_LOCK, REQ_LOCK,
                schedule.lockdown.hour, schedule.lockdown.minute, exact)
            ACTION_UNLOCK -> scheduleNext(context, am, ACTION_UNLOCK, REQ_UNLOCK,
                schedule.unlock.hour, schedule.unlock.minute, exact)
        }
    }

    fun cancelAll(context: Context) {
        val am = context.getSystemService(Context.ALARM_SERVICE) as AlarmManager
        for ((action, req) in listOf(
            ACTION_WIND_DOWN to REQ_WIND_DOWN,
            ACTION_LOCK to REQ_LOCK,
            ACTION_UNLOCK to REQ_UNLOCK,
        )) {
            am.cancel(pendingIntent(context, action, req))
        }
    }

    private fun scheduleNext(
        context: Context,
        am: AlarmManager,
        action: String,
        requestCode: Int,
        hour: Int,
        minute: Int,
        exact: Boolean,
    ) {
        val triggerAt = nextOccurrenceMillis(hour, minute)
        val pi = pendingIntent(context, action, requestCode)
        if (exact) {
            am.setExactAndAllowWhileIdle(AlarmManager.RTC_WAKEUP, triggerAt, pi)
        } else {
            // No exact-alarm access: use the idle-resilient inexact alarm. The
            // OS may batch it (a few minutes late) but it still fires through
            // Doze, which is what we need for an overnight schedule. The
            // `degraded` flag (set by the caller) tells Dart to nudge the user
            // to grant exact alarms for on-the-minute accuracy.
            am.setAndAllowWhileIdle(AlarmManager.RTC_WAKEUP, triggerAt, pi)
        }
    }

    /** Next wall-clock occurrence of [hour]:[minute], today or tomorrow. */
    private fun nextOccurrenceMillis(hour: Int, minute: Int): Long {
        val now = Calendar.getInstance()
        val next = Calendar.getInstance().apply {
            set(Calendar.HOUR_OF_DAY, hour.coerceIn(0, 23))
            set(Calendar.MINUTE, minute.coerceIn(0, 59))
            set(Calendar.SECOND, 0)
            set(Calendar.MILLISECOND, 0)
        }
        if (!next.after(now)) {
            next.add(Calendar.DAY_OF_YEAR, 1)
        }
        return next.timeInMillis
    }

    private fun pendingIntent(context: Context, action: String, requestCode: Int): PendingIntent {
        val intent = Intent(context, AlarmReceiver::class.java).apply {
            this.action = ACTION_ALARM
            putExtra(EXTRA_ACTION, action)
        }
        var flags = PendingIntent.FLAG_UPDATE_CURRENT
        flags = flags or PendingIntent.FLAG_IMMUTABLE
        return PendingIntent.getBroadcast(context, requestCode, intent, flags)
    }
}
