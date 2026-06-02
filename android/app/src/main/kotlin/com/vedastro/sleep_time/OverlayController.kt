package com.vedastro.sleep_time

import android.content.Context
import android.content.Intent
import android.graphics.PixelFormat
import android.os.Build
import android.os.PowerManager
import android.provider.Settings
import android.view.Gravity
import android.view.LayoutInflater
import android.view.View
import android.view.WindowManager
import android.widget.TextView

/**
 * Owns the native blocking overlay (full screen) and the slim grant countdown
 * banner. Both use [WindowManager.LayoutParams.TYPE_APPLICATION_OVERLAY] and the
 * user-granted SYSTEM_ALERT_WINDOW permission.
 *
 * ## Fallback
 * A secure app can call `setHideOverlayWindows(true)`, which makes our overlay
 * invisible (and `addView` can throw on some OEMs). Whenever adding/showing the
 * overlay fails, we fall back to bringing [MainActivity] to the front instead,
 * so the lock is never silently bypassed.
 *
 * ## Wake lock
 * A screen-bright wake lock is held ONLY while an overlay is visible, and is
 * released as soon as it is hidden. We never hold it in the background.
 */
class OverlayController(private val context: Context) {

    private val windowManager =
        context.getSystemService(Context.WINDOW_SERVICE) as WindowManager

    private var fullView: View? = null
    private var bannerView: View? = null
    private var wakeLock: PowerManager.WakeLock? = null

    /** Whether the user has granted "draw over other apps". */
    fun canDrawOverlay(): Boolean =
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.M) {
            Settings.canDrawOverlays(context)
        } else {
            true
        }

    /**
     * Show the full-screen blocking overlay. Returns true if the overlay was
     * actually shown; false if we fell back to launching the activity (e.g. no
     * permission, or the window system refused the view).
     */
    fun showFullBlock(): Boolean {
        hideBanner()
        if (!canDrawOverlay()) {
            bringActivityToFront()
            return false
        }
        if (fullView != null) return true

        val view = try {
            LayoutInflater.from(context).inflate(
                context.resources.getIdentifier(
                    "overlay_lockdown", "layout", context.packageName,
                ),
                null,
            )
        } catch (_: Exception) {
            bringActivityToFront()
            return false
        }

        view.findViewById<TextView>(
            context.resources.getIdentifier("overlay_open_button", "id", context.packageName),
        )?.setOnClickListener { bringActivityToFront() }

        val params = WindowManager.LayoutParams(
            WindowManager.LayoutParams.MATCH_PARENT,
            WindowManager.LayoutParams.MATCH_PARENT,
            overlayType(),
            WindowManager.LayoutParams.FLAG_KEEP_SCREEN_ON or
                WindowManager.LayoutParams.FLAG_NOT_TOUCH_MODAL,
            PixelFormat.OPAQUE,
        ).apply { gravity = Gravity.CENTER }

        return try {
            windowManager.addView(view, params)
            fullView = view
            acquireWakeLock()
            true
        } catch (_: Exception) {
            // setHideOverlayWindows / OEM refusal → fall back.
            bringActivityToFront()
            false
        }
    }

    /** Show / update the slim grant countdown banner with [remainingLabel]. */
    fun showBanner(remainingLabel: String): Boolean {
        hideFullBlock()
        if (!canDrawOverlay()) return false

        var view = bannerView
        if (view == null) {
            view = try {
                LayoutInflater.from(context).inflate(
                    context.resources.getIdentifier(
                        "overlay_banner", "layout", context.packageName,
                    ),
                    null,
                )
            } catch (_: Exception) {
                return false
            }
            view.setOnClickListener { bringActivityToFront() }
            val params = WindowManager.LayoutParams(
                WindowManager.LayoutParams.MATCH_PARENT,
                WindowManager.LayoutParams.WRAP_CONTENT,
                overlayType(),
                WindowManager.LayoutParams.FLAG_NOT_FOCUSABLE or
                    WindowManager.LayoutParams.FLAG_NOT_TOUCH_MODAL,
                PixelFormat.TRANSLUCENT,
            ).apply { gravity = Gravity.TOP }
            try {
                windowManager.addView(view, params)
                bannerView = view
                acquireWakeLock()
            } catch (_: Exception) {
                return false
            }
        }
        view.findViewById<TextView>(
            context.resources.getIdentifier("banner_countdown", "id", context.packageName),
        )?.text = remainingLabel
        return true
    }

    fun hideFullBlock() {
        fullView?.let {
            try {
                windowManager.removeView(it)
            } catch (_: Exception) {
            }
        }
        fullView = null
        maybeReleaseWakeLock()
    }

    fun hideBanner() {
        bannerView?.let {
            try {
                windowManager.removeView(it)
            } catch (_: Exception) {
            }
        }
        bannerView = null
        maybeReleaseWakeLock()
    }

    /** Tear everything down (called when the guardian stops or unlock fires). */
    fun hideAll() {
        hideFullBlock()
        hideBanner()
    }

    /**
     * Fallback when the overlay cannot be shown: bring the Flutter activity to
     * the front so the user still lands on the negotiation UI rather than the
     * blocked app.
     */
    fun bringActivityToFront() {
        try {
            val intent = Intent(context, MainActivity::class.java).apply {
                addFlags(
                    Intent.FLAG_ACTIVITY_NEW_TASK or
                        Intent.FLAG_ACTIVITY_REORDER_TO_FRONT,
                )
            }
            context.startActivity(intent)
        } catch (_: Exception) {
        }
    }

    private fun overlayType(): Int =
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            WindowManager.LayoutParams.TYPE_APPLICATION_OVERLAY
        } else {
            @Suppress("DEPRECATION")
            WindowManager.LayoutParams.TYPE_SYSTEM_ALERT
        }

    private fun acquireWakeLock() {
        if (wakeLock?.isHeld == true) return
        val pm = context.getSystemService(Context.POWER_SERVICE) as PowerManager
        @Suppress("DEPRECATION")
        val lock = pm.newWakeLock(
            PowerManager.SCREEN_BRIGHT_WAKE_LOCK or PowerManager.ACQUIRE_CAUSES_WAKEUP,
            "sleep_time:overlay",
        )
        try {
            lock.acquire(10 * 60 * 1000L) // safety timeout; refreshed by re-show
            wakeLock = lock
        } catch (_: Exception) {
        }
    }

    private fun maybeReleaseWakeLock() {
        if (fullView == null && bannerView == null) {
            wakeLock?.let {
                if (it.isHeld) {
                    try {
                        it.release()
                    } catch (_: Exception) {
                    }
                }
            }
            wakeLock = null
        }
    }
}
