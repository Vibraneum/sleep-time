package com.vedastro.sleep_time

import android.content.Context
import android.content.SharedPreferences
import org.json.JSONArray
import org.json.JSONObject

/**
 * Persisted, time-limited per-app allow-list — the native source of truth for
 * which packages are allowed through while the bedtime lock is active.
 *
 * ## Storage
 * Entries persist into the **`FlutterSharedPreferences`** file under the key
 * `flutter.app_allowlist` so the native list and the Dart-side
 * `lib/core/app_allowlist.dart` (`AppAllowlist`) read/write the *same* blob.
 * The format mirrors Dart exactly: a JSON array of
 * `{identifier, label, expires_at}` where `expires_at` is an ISO-8601 string.
 *
 * ## Always-allowed packages
 * Our own package and the current default launcher are ALWAYS allowed (we must
 * never block the user from reaching Sleep Time or the home screen). These are
 * not persisted — they are computed live in [isAllowed].
 *
 * All reads are defensive: a missing/garbled blob is treated as empty so the
 * guardian never crashes on a fresh or corrupted prefs file.
 */
object AllowListManager {
    private const val PREFS_NAME = "FlutterSharedPreferences"
    private const val KEY = "flutter.app_allowlist"

    // Serializes read-modify-write of the persisted blob so concurrent allow()/
    // purgeExpired() calls (activity vs service threads) cannot clobber each
    // other and silently drop grants.
    private val lock = Any()

    private fun prefs(context: Context): SharedPreferences =
        context.getSharedPreferences(PREFS_NAME, Context.MODE_PRIVATE)

    /** A single allowed package with an absolute expiry (epoch millis). */
    data class Entry(
        val identifier: String,
        val label: String,
        val expiresAtMillis: Long,
    ) {
        fun isActive(nowMillis: Long = System.currentTimeMillis()): Boolean =
            nowMillis < expiresAtMillis
    }

    /**
     * True when [pkg] may run in the foreground right now: it is our own app,
     * the default launcher, or an active (non-expired) allow-list entry.
     */
    fun isAllowed(context: Context, pkg: String?): Boolean {
        if (pkg.isNullOrEmpty()) return true // unknown → don't block spuriously
        if (pkg == context.packageName) return true
        if (pkg == defaultLauncherPackage(context)) return true
        val now = System.currentTimeMillis()
        return readAll(context).any { it.identifier == pkg && it.isActive(now) }
    }

    /** Currently-active (non-expired) entries, excluding the always-allowed set. */
    fun activeEntries(context: Context): List<Entry> {
        val now = System.currentTimeMillis()
        return readAll(context).filter { it.isActive(now) }
    }

    /** Add/refresh a time-limited grant for [pkg]. [minutes] is clamped >= 1. */
    fun allow(context: Context, pkg: String, label: String, minutes: Int) {
        if (pkg.isEmpty()) return
        synchronized(lock) {
            val safeMinutes = minutes.coerceAtLeast(1)
            val expiresAt = System.currentTimeMillis() + safeMinutes * 60_000L
            val current = readAll(context).toMutableList()
            current.removeAll { it.identifier == pkg }
            current.add(Entry(pkg, label.ifEmpty { pkg }, expiresAt))
            writeAll(context, current)
        }
    }

    /** Drop expired entries; returns true if anything changed. */
    fun purgeExpired(context: Context): Boolean {
        synchronized(lock) {
            val now = System.currentTimeMillis()
            val all = readAll(context)
            val kept = all.filter { it.isActive(now) }
            if (kept.size != all.size) {
                writeAll(context, kept)
                return true
            }
            return false
        }
    }

    /** Soonest expiry across active entries, or 0L when none. */
    fun nextExpiryMillis(context: Context): Long {
        val now = System.currentTimeMillis()
        return readAll(context)
            .filter { it.isActive(now) }
            .minOfOrNull { it.expiresAtMillis } ?: 0L
    }

    private fun readAll(context: Context): List<Entry> {
        val raw = prefs(context).getString(KEY, null) ?: return emptyList()
        if (raw.isEmpty()) return emptyList()
        return try {
            val arr = JSONArray(raw)
            buildList {
                for (i in 0 until arr.length()) {
                    val obj = arr.optJSONObject(i) ?: continue
                    val id = obj.optString("identifier")
                    if (id.isEmpty()) continue
                    add(
                        Entry(
                            identifier = id,
                            label = obj.optString("label", id),
                            expiresAtMillis = parseIso(obj.optString("expires_at")),
                        ),
                    )
                }
            }
        } catch (_: Exception) {
            emptyList()
        }
    }

    private fun writeAll(context: Context, entries: List<Entry>) {
        val arr = JSONArray()
        for (e in entries) {
            arr.put(
                JSONObject().apply {
                    put("identifier", e.identifier)
                    put("label", e.label)
                    put("expires_at", formatIso(e.expiresAtMillis))
                },
            )
        }
        prefs(context).edit().putString(KEY, arr.toString()).apply()
    }

    /**
     * Parse the subset of ISO-8601 that Dart's [DateTime.toIso8601String]
     * emits (`yyyy-MM-ddTHH:mm:ss.SSS`, no zone = local). We parse with a
     * SimpleDateFormat in the default zone; any failure yields 0 (treated as
     * already-expired, the safe default — never accidentally allow).
     */
    private fun parseIso(value: String): Long {
        if (value.isEmpty()) return 0L
        return try {
            val fmt = java.text.SimpleDateFormat(
                "yyyy-MM-dd'T'HH:mm:ss.SSS",
                java.util.Locale.US,
            )
            // Dart local-time ISO strings carry no zone; trim a trailing 'Z' or
            // offset if present, then parse in the default (device) zone.
            val trimmed = value.substringBefore('Z').substringBefore('+')
            (fmt.parse(trimmed)?.time) ?: 0L
        } catch (_: Exception) {
            0L
        }
    }

    private fun formatIso(millis: Long): String {
        val fmt = java.text.SimpleDateFormat(
            "yyyy-MM-dd'T'HH:mm:ss.SSS",
            java.util.Locale.US,
        )
        return fmt.format(java.util.Date(millis))
    }

    private fun defaultLauncherPackage(context: Context): String? {
        return try {
            val intent = android.content.Intent(android.content.Intent.ACTION_MAIN)
                .addCategory(android.content.Intent.CATEGORY_HOME)
            val info = context.packageManager.resolveActivity(
                intent,
                android.content.pm.PackageManager.MATCH_DEFAULT_ONLY,
            )
            info?.activityInfo?.packageName
        } catch (_: Exception) {
            null
        }
    }
}
