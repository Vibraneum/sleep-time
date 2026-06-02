package com.vedastro.sleep_time

import android.content.Context
import androidx.work.Worker
import androidx.work.WorkerParameters

/**
 * Expedited boot-recovery worker enqueued by [BootReceiver].
 *
 *  1. Re-arms all bedtime alarms from the persisted schedule.
 *  2. If the device is currently inside the lockdown window, starts the
 *     guardian foreground service. Starting an FGS from a WorkManager worker is
 *     an allowed exemption (unlike a direct BOOT_COMPLETED start of a
 *     specialUse FGS, which Android 15 bans).
 *
 * Outside the lockdown window we leave the service stopped; the freshly armed
 * alarms will start it at the next transition.
 */
class GuardianBootWorker(
    appContext: Context,
    params: WorkerParameters,
) : Worker(appContext, params) {

    override fun doWork(): Result {
        val context = applicationContext
        return try {
            SleepAlarmScheduler.rescheduleAll(context)

            val schedule = SleepScheduleStore.read(context)
            if (schedule.isInLockdownWindow(Schedule.nowMinutes())) {
                SleepGuardianService.start(context)
            }
            Result.success()
        } catch (_: Exception) {
            // Retry once; a transient failure right after boot is plausible.
            Result.retry()
        }
    }
}
