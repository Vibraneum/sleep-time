package com.vedastro.sleep_time

import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent

/**
 * Fires on each scheduled WIND_DOWN / LOCK / UNLOCK alarm. It:
 *  1. self-reschedules the next day's occurrence of the same alarm (+24h),
 *  2. asks [SleepGuardianService] to re-evaluate + transition state.
 *
 * Doing the reschedule first keeps the nightly cadence alive even if the
 * service start is throttled.
 */
class AlarmReceiver : BroadcastReceiver() {
    override fun onReceive(context: Context, intent: Intent) {
        if (intent.action != SleepAlarmScheduler.ACTION_ALARM) return
        val action = intent.getStringExtra(SleepAlarmScheduler.EXTRA_ACTION)

        // Re-arm tomorrow's occurrence of this alarm.
        if (action != null) {
            SleepAlarmScheduler.rescheduleOne(context, action)
        }

        // Ask the service to re-evaluate. The service promotes itself to the
        // foreground; this start originates from an alarm (an allowed FGS-start
        // exemption), not from BOOT_COMPLETED.
        SleepGuardianService.evaluate(context, action)
    }
}
