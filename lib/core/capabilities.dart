import 'dart:io';

/// Describes what enforcement the current platform/flavor permits. This is the
/// seam the later `play` vs `full` build flavors will swap to advertise (and
/// gate) different enforcement powers.
///
// TODO(full-flavor): swap [current] based on the active build flavor so the
// Play-compliant build can advertise reduced enforcement while the sideloaded
// "full" build unlocks whole-device lockdown + background service on Android.
class Capabilities {
  /// Can the platform lock down the whole device (vs. just selected apps)?
  final bool canBlockWholeDevice;

  /// Can the platform selectively allow individual apps through lockdown?
  final bool canSelectivelyAllowApps;

  /// Does enforcement require a persistent background service?
  final bool canRunBackgroundService;

  /// Is this a Play Store-policy-compliant build?
  final bool isPlayCompliantBuild;

  const Capabilities({
    required this.canBlockWholeDevice,
    required this.canSelectivelyAllowApps,
    required this.canRunBackgroundService,
    required this.isPlayCompliantBuild,
  });

  /// The capabilities for the current platform. Single default implementation
  /// for M0 — no flavor wiring yet.
  static Capabilities get current {
    if (Platform.isAndroid) {
      return const Capabilities(
        canBlockWholeDevice: false,
        canSelectivelyAllowApps: true,
        canRunBackgroundService: true,
        isPlayCompliantBuild: true,
      );
    }
    // Windows (and other desktop) — whole-device takeover, selective allow,
    // no dedicated background service needed.
    return const Capabilities(
      canBlockWholeDevice: true,
      canSelectivelyAllowApps: true,
      canRunBackgroundService: false,
      isPlayCompliantBuild: true,
    );
  }
}
