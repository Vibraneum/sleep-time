/// Time-of-night warm copy for the guardian / overlay.
///
/// The tone gets gentler near the start of bedtime and a touch firmer in the
/// small hours, but stays caring throughout. Red is reserved for the final
/// 2-minute countdown only (handled by the caller, not here); nothing in this
/// table is alarming.
///
/// Pure data + selection logic so it is testable without a device (see
/// test/guardian_copy_test.dart).
library;

/// A coarse bucket of the night used to pick copy.
enum NightBucket {
  /// Around wind-down / just before lockdown (~before midnight).
  earlyEvening,

  /// The core bedtime hours (~midnight to ~2am).
  lateNight,

  /// The small hours (~2am to ~5am) — firmest, most concerned tone.
  smallHours,

  /// Near morning (~5am onward) — the lock is about to lift.
  preDawn,
}

/// A warm copy line for the overlay / guardian, with an optional sub-line.
class GuardianLine {
  final String headline;
  final String subline;

  const GuardianLine(this.headline, this.subline);
}

abstract final class GuardianCopy {
  /// Bucket an hour-of-day (0..23) into a [NightBucket].
  static NightBucket bucketForHour(int hour) {
    final h = hour % 24;
    // 2..5 small hours; 5..9 pre-dawn; 21..24 + 0..2 split across evening/late.
    if (h >= 2 && h < 5) return NightBucket.smallHours;
    if (h >= 5 && h < 9) return NightBucket.preDawn;
    if (h >= 0 && h < 2) return NightBucket.lateNight;
    // Evening: 21:00 onward counts as early evening (around wind-down).
    return NightBucket.earlyEvening;
  }

  /// The full-block headline/subline for a given hour.
  static GuardianLine blockLineForHour(int hour) {
    switch (bucketForHour(hour)) {
      case NightBucket.earlyEvening:
        return const GuardianLine(
          'Time to wind down',
          "The day's done. Let's get you to bed gently — tap below if you "
              'really need a moment.',
        );
      case NightBucket.lateNight:
        return const GuardianLine(
          "It's bedtime",
          'This can almost certainly wait for morning. Talk to me if it '
              "truly can't.",
        );
      case NightBucket.smallHours:
        return const GuardianLine(
          "It's the middle of the night",
          'Whatever this is, future-you will thank you for sleeping. '
              "I'm here if it's genuinely urgent.",
        );
      case NightBucket.preDawn:
        return const GuardianLine(
          'Almost morning',
          'The lock lifts soon — try to rest until then. Tap if you need '
              'me.',
        );
    }
  }

  /// A short banner label for an active grant at a given hour.
  static String grantBannerLabelForHour(int hour) {
    switch (bucketForHour(hour)) {
      case NightBucket.earlyEvening:
        return 'A little longer';
      case NightBucket.lateNight:
        return 'Borrowed time';
      case NightBucket.smallHours:
        return 'Just this once';
      case NightBucket.preDawn:
        return 'Wrapping up';
    }
  }
}
