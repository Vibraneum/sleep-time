package com.vedastro.sleep_time

import android.content.Context
import java.util.Calendar

/**
 * Reads the bedtime [Schedule] (and the safe/simulate flag) from the same
 * SharedPreferences file Flutter's `shared_preferences` plugin writes to.
 *
 * ## Encoding assumptions (must match the Dart side)
 *
 * - `shared_preferences` stores everything under the **`FlutterSharedPreferences`**
 *   prefs file with every key **prefixed `flutter.`**. So the Dart key
 *   `lockdown_hour` is read here as `flutter.lockdown_hour`.
 * - Dart `int`s are persisted by the plugin as **`Long`** values. We therefore
 *   read them with [android.content.SharedPreferences.getLong] and narrow to
 *   `Int`. Reading them as `Int` would throw `ClassCastException`.
 * - Dart `bool`s are stored as native booleans (`getBoolean`).
 *
 * Schedule keys (see lib/core/schedule_store.dart):
 *   wakeup_hour / wakeup_minute, winddown_hour / winddown_minute,
 *   lockdown_hour / lockdown_minute, unlock_hour / unlock_minute.
 * Simulate flag key (see lib/main.dart `_loadConfig`): simulate_lockdown.
 *
 * All reads are defensive: a missing/garbled value falls back to the shipped
 * defaults so the guardian never crashes on a fresh or corrupted prefs file.
 */
object SleepScheduleStore {
    private const val PREFS_NAME = "FlutterSharedPreferences"
    private const val PREFIX = "flutter."

    // Mirror SleepSchedule.defaults in lib/core/schedule.dart.
    private const val DEFAULT_WAKEUP_HOUR = 22
    private const val DEFAULT_WAKEUP_MINUTE = 30
    private const val DEFAULT_WINDDOWN_HOUR = 23
    private const val DEFAULT_WINDDOWN_MINUTE = 0
    private const val DEFAULT_LOCKDOWN_HOUR = 23
    private const val DEFAULT_LOCKDOWN_MINUTE = 30
    private const val DEFAULT_UNLOCK_HOUR = 6
    private const val DEFAULT_UNLOCK_MINUTE = 0

    /** Whether the user/dev has the app in safe (simulate) mode. */
    fun isSimulating(context: Context): Boolean {
        val prefs = context.getSharedPreferences(PREFS_NAME, Context.MODE_PRIVATE)
        return prefs.getBoolean(PREFIX + "simulate_lockdown", false)
    }

    fun read(context: Context): Schedule {
        val prefs = context.getSharedPreferences(PREFS_NAME, Context.MODE_PRIVATE)

        fun int(key: String, default: Int): Int = try {
            // shared_preferences stores Dart ints as Long.
            prefs.getLong(PREFIX + key, default.toLong()).toInt()
        } catch (_: ClassCastException) {
            // Be lenient if a value was ever written as a plain Int.
            try {
                prefs.getInt(PREFIX + key, default)
            } catch (_: ClassCastException) {
                default
            }
        }

        return Schedule(
            wakeUp = TimeOfDay(
                int("wakeup_hour", DEFAULT_WAKEUP_HOUR),
                int("wakeup_minute", DEFAULT_WAKEUP_MINUTE),
            ),
            windDown = TimeOfDay(
                int("winddown_hour", DEFAULT_WINDDOWN_HOUR),
                int("winddown_minute", DEFAULT_WINDDOWN_MINUTE),
            ),
            lockdown = TimeOfDay(
                int("lockdown_hour", DEFAULT_LOCKDOWN_HOUR),
                int("lockdown_minute", DEFAULT_LOCKDOWN_MINUTE),
            ),
            unlock = TimeOfDay(
                int("unlock_hour", DEFAULT_UNLOCK_HOUR),
                int("unlock_minute", DEFAULT_UNLOCK_MINUTE),
            ),
        )
    }
}

/** A wall-clock time of day in 24h form. */
data class TimeOfDay(val hour: Int, val minute: Int) {
    /** Minutes since midnight, clamped to a sane 0..1439 range. */
    val minutesOfDay: Int
        get() = ((hour.coerceIn(0, 23)) * 60) + minute.coerceIn(0, 59)
}

/**
 * The nightly schedule with the same wrap-aware window logic as the Dart
 * `AppConfig` helpers. Times mirror `lib/core/schedule.dart`.
 */
data class Schedule(
    val wakeUp: TimeOfDay,
    val windDown: TimeOfDay,
    val lockdown: TimeOfDay,
    val unlock: TimeOfDay,
) {
    /**
     * True when [nowMinutes] (minutes since midnight) is inside the
     * lockdown -> unlock window, treating a window that crosses midnight
     * correctly (e.g. lockdown 23:30, unlock 06:00).
     */
    fun isInLockdownWindow(nowMinutes: Int): Boolean =
        withinWindow(lockdown.minutesOfDay, unlock.minutesOfDay, nowMinutes)

    /** True when [nowMinutes] is inside the windDown -> lockdown window. */
    fun isInWindDownWindow(nowMinutes: Int): Boolean =
        withinWindow(windDown.minutesOfDay, lockdown.minutesOfDay, nowMinutes)

    companion object {
        /** Mirrors AppConfig._isWithinWindow in lib/core/config.dart. */
        fun withinWindow(startMinutes: Int, endMinutes: Int, current: Int): Boolean {
            if (startMinutes == endMinutes) return true
            return if (startMinutes < endMinutes) {
                current in startMinutes until endMinutes
            } else {
                current >= startMinutes || current < endMinutes
            }
        }

        /** Minutes since midnight for "now". */
        fun nowMinutes(cal: Calendar = Calendar.getInstance()): Int =
            cal.get(Calendar.HOUR_OF_DAY) * 60 + cal.get(Calendar.MINUTE)
    }
}
