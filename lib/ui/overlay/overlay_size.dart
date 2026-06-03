/// How much of the screen the lockdown / grant UI should occupy.
///
/// - [full]   — the whole-screen lockdown / negotiate surface (locked state).
/// - [banner] — a slim top/bottom strip with a countdown (active grant).
/// - [mini]   — a compact corner pill, the most unobtrusive grant readout.
enum OverlaySize { full, banner, mini }

/// Pure selection logic for which [OverlaySize] to render, given the current
/// situation. Kept side-effect free and platform-free so it is trivially
/// testable (see test/overlay_size_test.dart).
abstract final class OverlaySizing {
  /// Choose the overlay size.
  ///
  /// - While [locked] and NOT granted → [OverlaySize.full] (block + negotiate).
  /// - During a grant ([granted] true): a per-app grant or a "fold to corner"
  ///   full grant collapses to [OverlaySize.mini]; a plain timed grant shows the
  ///   [OverlaySize.banner] countdown.
  /// - Otherwise (no lock, no grant) → [OverlaySize.banner] as a harmless
  ///   default; callers typically hide the overlay entirely in that case.
  static OverlaySize select({
    required bool locked,
    required bool granted,
    bool perAppGrant = false,
    bool foldToCorner = false,
  }) {
    if (locked && !granted) return OverlaySize.full;
    if (granted) {
      if (perAppGrant || foldToCorner) return OverlaySize.mini;
      return OverlaySize.banner;
    }
    return OverlaySize.banner;
  }
}
