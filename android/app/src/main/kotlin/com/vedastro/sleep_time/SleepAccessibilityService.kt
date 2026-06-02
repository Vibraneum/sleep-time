package com.vedastro.sleep_time

import android.accessibilityservice.AccessibilityService
import android.view.accessibility.AccessibilityEvent

/**
 * OPTIONAL latency enhancement. Observe-only.
 *
 * When the user enables this (after the in-app prominent-disclosure dialog), it
 * forwards `typeWindowStateChanged` package names straight to the running
 * [SleepGuardianService] so the lock can react to an app switch a little faster
 * than the ~1s UsageStats poll. It does NOT read screen content, inject input,
 * or make any decision itself — the guardian's evaluation path is identical with
 * or without this service, and is fully functional when it is disabled or
 * revoked (e.g. by Android 17 Advanced Protection).
 *
 * Deliberately NOT flagged isAccessibilityTool: this is a Digital Wellbeing
 * helper, not assistive technology.
 */
class SleepAccessibilityService : AccessibilityService() {

    private var lastPackage: String? = null
    private var lastEventAt = 0L
    private val debounceMs = 500L

    override fun onAccessibilityEvent(event: AccessibilityEvent?) {
        if (event == null) return
        if (event.eventType != AccessibilityEvent.TYPE_WINDOW_STATE_CHANGED) return

        val now = System.currentTimeMillis()
        if (now - lastEventAt < debounceMs) return
        lastEventAt = now

        val pkg = event.packageName?.toString() ?: return
        if (pkg.isEmpty() || pkg == lastPackage) return
        lastPackage = pkg

        // Hand the package to the guardian; it owns the (UsageStats-primary)
        // evaluation. This is purely a faster nudge into the same path.
        SleepGuardianService.onAccessibilityForeground(this, pkg)
    }

    override fun onInterrupt() {
        // No-op: observe-only.
    }
}
