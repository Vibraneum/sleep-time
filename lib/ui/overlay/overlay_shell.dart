import 'package:flutter/material.dart';

import 'guardian_copy.dart';
import 'overlay_size.dart';

/// A reusable lockdown / grant shell rendered at one of three [OverlaySize]s,
/// shared between the Windows and Android lockdown screens.
///
/// - [OverlaySize.full]   → renders [fullChild] (the whole-screen negotiate UI).
/// - [OverlaySize.banner] → a slim countdown strip.
/// - [OverlaySize.mini]   → a compact corner pill (per-app or fold-to-corner
///   grant).
///
/// Design language: dark bedtime surface `0xFF0D0D1A`, indigo `0xFF5B5FEF`,
/// amber `0xFFFF9500` for countdowns; red `0xFFFF3B30` ONLY in the final two
/// minutes ([urgent]). The caring chat surface never uses red.
class OverlayShell extends StatelessWidget {
  final OverlaySize size;

  /// Whole-screen content (negotiation). Required for [OverlaySize.full].
  final Widget? fullChild;

  /// Countdown remaining, for banner / mini. Null hides the timer.
  final Duration? remaining;

  /// For a per-app grant: the friendly app name being borrowed.
  final String? appLabel;

  /// Tapped on banner / mini (e.g. open the negotiation chat).
  final VoidCallback? onTapExpand;

  /// "Back to sleep early" action on a grant view.
  final VoidCallback? onEndEarly;

  const OverlayShell({
    super.key,
    required this.size,
    this.fullChild,
    this.remaining,
    this.appLabel,
    this.onTapExpand,
    this.onEndEarly,
  });

  bool get _urgent =>
      remaining != null && remaining!.inSeconds > 0 && remaining!.inMinutes < 2;

  static const _bg = Color(0xFF0D0D1A);
  static const _amber = Color(0xFFFF9500);
  static const _red = Color(0xFFFF3B30);

  Color get _timerColor => _urgent ? _red : _amber;

  String _formatRemaining() {
    final r = remaining;
    if (r == null) return '--:--';
    final mins = r.inMinutes;
    final secs = r.inSeconds % 60;
    return '${mins.toString().padLeft(2, '0')}:${secs.toString().padLeft(2, '0')}';
  }

  @override
  Widget build(BuildContext context) {
    switch (size) {
      case OverlaySize.full:
        return fullChild ?? const SizedBox.shrink();
      case OverlaySize.banner:
        return _buildBanner();
      case OverlaySize.mini:
        return _buildMini();
    }
  }

  Widget _buildBanner() {
    final label = appLabel == null
        ? GuardianCopy.grantBannerLabelForHour(DateTime.now().hour)
        : appLabel!;
    return Material(
      color: Colors.transparent,
      child: GestureDetector(
        onTap: onTapExpand,
        child: Container(
          width: double.infinity,
          padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 14),
          decoration: BoxDecoration(
            color: _bg.withAlpha(230),
            borderRadius: BorderRadius.circular(16),
          ),
          child: Row(
            children: [
              Icon(
                appLabel == null ? Icons.timer_outlined : Icons.apps_rounded,
                color: _timerColor,
                size: 18,
              ),
              const SizedBox(width: 10),
              Expanded(
                child: Text(
                  label,
                  style: TextStyle(
                    color: Colors.white.withAlpha(200),
                    fontSize: 14,
                  ),
                  overflow: TextOverflow.ellipsis,
                ),
              ),
              Text(
                _formatRemaining(),
                style: TextStyle(
                  color: _timerColor,
                  fontSize: 16,
                  fontWeight: FontWeight.w600,
                  letterSpacing: 1,
                ),
              ),
              if (onEndEarly != null) ...[
                const SizedBox(width: 12),
                _endEarlyButton(),
              ],
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildMini() {
    return Material(
      color: Colors.transparent,
      child: GestureDetector(
        onTap: onTapExpand,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.end,
          children: [
            Container(
              padding:
                  const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
              decoration: BoxDecoration(
                color: _bg.withAlpha(235),
                borderRadius: BorderRadius.circular(20),
              ),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  if (appLabel != null) ...[
                    Flexible(
                      child: Text(
                        appLabel!,
                        style: TextStyle(
                          color: Colors.white.withAlpha(180),
                          fontSize: 12,
                        ),
                        overflow: TextOverflow.ellipsis,
                      ),
                    ),
                    const SizedBox(width: 8),
                  ],
                  Text(
                    _formatRemaining(),
                    style: TextStyle(
                      color: _timerColor,
                      fontSize: 14,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                ],
              ),
            ),
            if (onEndEarly != null) ...[
              const SizedBox(height: 8),
              _endEarlyButton(),
            ],
          ],
        ),
      ),
    );
  }

  Widget _endEarlyButton() {
    return GestureDetector(
      onTap: onEndEarly,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(12),
          border: Border.all(color: Colors.white.withAlpha(40)),
        ),
        child: Text(
          'Back to sleep early',
          style: TextStyle(
            color: Colors.white.withAlpha(150),
            fontSize: 12,
          ),
        ),
      ),
    );
  }
}
