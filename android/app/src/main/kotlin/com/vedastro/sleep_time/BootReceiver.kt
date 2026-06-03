package com.vedastro.sleep_time

import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import androidx.work.OneTimeWorkRequestBuilder
import androidx.work.OutOfQuotaPolicy
import androidx.work.WorkManager

/**
 * Re-arms the bedtime alarms after a reboot.
 *
 * Android 15 forbids starting a `specialUse` foreground service directly from a
 * BOOT_COMPLETED broadcast, so we do NOT call startForegroundService here.
 * Instead we enqueue an **expedited** WorkManager job ([GuardianBootWorker])
 * which reschedules the alarms and — only if the device is currently inside the
 * lockdown window — starts the guardian service (a WorkManager-originated start
 * is permitted).
 */
class BootReceiver : BroadcastReceiver() {
    override fun onReceive(context: Context, intent: Intent) {
        val action = intent.action
        if (action != Intent.ACTION_BOOT_COMPLETED &&
            action != Intent.ACTION_LOCKED_BOOT_COMPLETED
        ) {
            return
        }

        val request = OneTimeWorkRequestBuilder<GuardianBootWorker>()
            .setExpedited(OutOfQuotaPolicy.RUN_AS_NON_EXPEDITED_WORK_REQUEST)
            .build()
        WorkManager.getInstance(context.applicationContext)
            .enqueue(request)
    }
}
