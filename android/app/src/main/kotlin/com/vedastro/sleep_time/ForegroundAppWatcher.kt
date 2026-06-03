package com.vedastro.sleep_time

import android.app.AppOpsManager
import android.app.usage.UsageEvents
import android.app.usage.UsageStatsManager
import android.content.Context
import android.os.Build
import android.os.Handler
import android.os.Looper
import android.os.Process

/**
 * PRIMARY foreground-app detector.
 *
 * Polls [UsageStatsManager.queryEvents] roughly once a second to learn which
 * package most recently moved to the foreground. This is the source of truth
 * for the lock escalation; the optional [SleepAccessibilityService] only pushes
 * the same package in faster when present (see [onForegroundPackage]).
 *
 * The watcher only runs while the guardian is actively enforcing (locked, or an
 * active grant) — it is started/stopped by [SleepGuardianService], never a
 * standing background loop.
 *
 * Requires the user-granted PACKAGE_USAGE_STATS (Usage Access). When that is not
 * granted, [hasUsageAccess] is false and [latestForegroundPackage] returns null;
 * the guardian degrades gracefully (it cannot per-app block, but everything else
 * — schedule, notification, full overlay on app switch via accessibility if the
 * user enabled it — still works).
 */
class ForegroundAppWatcher(
    private val context: Context,
    private val pollIntervalMs: Long = 1_000L,
) {
    /** Called on the main thread whenever the detected foreground package changes. */
    var onForegroundPackage: ((String) -> Unit)? = null

    private val handler = Handler(Looper.getMainLooper())
    private var running = false
    private var lastPackage: String? = null
    // Look back far enough to survive a missed tick / device hiccup.
    private val lookbackMs = 10_000L

    fun start() {
        if (running) return
        if (!hasUsageAccess(context)) return
        running = true
        handler.post(pollRunnable)
    }

    fun stop() {
        running = false
        handler.removeCallbacks(pollRunnable)
        lastPackage = null
    }

    /** The detected foreground package, or null when unknown / no usage access. */
    fun latestForegroundPackage(): String? = computeForegroundPackage()

    /**
     * Feed a package observed by the optional AccessibilityService. Treated
     * exactly like a poll result so the evaluation path is identical whether the
     * signal came from UsageStats (primary) or accessibility (optional/faster).
     */
    fun pushAccessibilityPackage(pkg: String) {
        if (!running) return
        if (pkg.isEmpty() || pkg == lastPackage) return
        lastPackage = pkg
        onForegroundPackage?.invoke(pkg)
    }

    private val pollRunnable = object : Runnable {
        override fun run() {
            if (!running) return
            val pkg = computeForegroundPackage()
            if (pkg != null && pkg != lastPackage) {
                lastPackage = pkg
                onForegroundPackage?.invoke(pkg)
            }
            if (running) handler.postDelayed(this, pollIntervalMs)
        }
    }

    private fun computeForegroundPackage(): String? {
        val usm = context.getSystemService(Context.USAGE_STATS_SERVICE)
            as? UsageStatsManager ?: return null
        val now = System.currentTimeMillis()
        return try {
            val events = usm.queryEvents(now - lookbackMs, now)
            val event = UsageEvents.Event()
            var latestPkg: String? = null
            var latestTime = 0L
            while (events.hasNextEvent()) {
                events.getNextEvent(event)
                val isResume = event.eventType == UsageEvents.Event.MOVE_TO_FOREGROUND ||
                    (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q &&
                        event.eventType == UsageEvents.Event.ACTIVITY_RESUMED)
                if (isResume && event.timeStamp >= latestTime) {
                    latestTime = event.timeStamp
                    latestPkg = event.packageName
                }
            }
            latestPkg
        } catch (_: Exception) {
            null
        }
    }

    companion object {
        /** Whether the user has granted Usage Access to this app. */
        fun hasUsageAccess(context: Context): Boolean {
            return try {
                val appOps = context.getSystemService(Context.APP_OPS_SERVICE)
                    as? AppOpsManager ?: return false
                val mode = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
                    appOps.unsafeCheckOpNoThrow(
                        AppOpsManager.OPSTR_GET_USAGE_STATS,
                        Process.myUid(),
                        context.packageName,
                    )
                } else {
                    @Suppress("DEPRECATION")
                    appOps.checkOpNoThrow(
                        AppOpsManager.OPSTR_GET_USAGE_STATS,
                        Process.myUid(),
                        context.packageName,
                    )
                }
                mode == AppOpsManager.MODE_ALLOWED
            } catch (_: Exception) {
                false
            }
        }
    }
}
