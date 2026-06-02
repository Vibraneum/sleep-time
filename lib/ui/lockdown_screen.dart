import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:window_manager/window_manager.dart';
import '../core/lockdown_scheduler.dart';
import '../core/negotiation_engine.dart';
import '../core/config.dart';
import '../core/schedule_store.dart';
import '../core/negotiable_apps.dart';
import '../platform/windows_lockdown.dart';
import '../platform/windows_lock_state.dart';
import '../platform/android_lockdown.dart';
import 'negotiation_chat.dart';
import 'home_screen.dart';
import 'settings_screen.dart';
import 'overlay/overlay_shell.dart';
import 'overlay/overlay_size.dart';

class LockdownScreen extends StatefulWidget {
  final LockdownScheduler scheduler;

  /// The negotiation engine, OWNED by HomeScreen (above this screen's
  /// lifecycle) so conversation history survives grant -> relock -> new
  /// LockdownScreen. Falls back to a local engine if none is supplied (e.g. a
  /// direct test instantiation).
  final NegotiationEngine? engine;

  const LockdownScreen({super.key, required this.scheduler, this.engine});

  @override
  State<LockdownScreen> createState() => _LockdownScreenState();
}

class _LockdownScreenState extends State<LockdownScreen>
    with TickerProviderStateMixin, WindowListener {
  late final NegotiationEngine _engine = widget.engine ?? NegotiationEngine();
  bool get _ownsEngine => widget.engine == null;

  /// Focus node for the chat TextField. Owned here (not by NegotiationChat) so
  /// onWindowFocus can re-request keyboard focus after a native foreground
  /// reclaim — that is the fix for "typing gets eaten" during takeover.
  final _chatFocusNode = FocusNode();

  bool _showChat = false;
  late AnimationController _pulseController;

  /// When set, the active grant is a per-app unlock (Android selective unlock):
  /// the granted view shows the borrowed app's friendly name instead of the
  /// generic full-grant countdown.
  String? _grantedAppLabel;

  @override
  void initState() {
    super.initState();
    if (Platform.isWindows) {
      windowManager.addListener(this);
    }
    _pulseController = AnimationController(
      vsync: this,
      duration: const Duration(seconds: 3),
    )..repeat(reverse: true);
  }

  @override
  void dispose() {
    if (Platform.isWindows) {
      windowManager.removeListener(this);
    }
    _pulseController.dispose();
    _chatFocusNode.dispose();
    // Only dispose the engine if WE created it. When HomeScreen owns it, the
    // engine must outlive this screen (so history survives grant -> relock).
    if (_ownsEngine) _engine.dispose();
    super.dispose();
  }

  void _onGranted(int minutes) {
    widget.scheduler.grantExtension(minutes);
    setState(() {
      _grantedAppLabel = null;
      _showChat = false;
    });
    // A full grant frees the whole machine — get out of the way automatically so
    // the user can actually use their earned time (the platform takeover is
    // already released by _syncPlatformLockdown on the `granted` transition).
    _minimizeOutOfTheWay();
  }

  /// Send the window to the taskbar so the guardian keeps running in the
  /// background without covering the screen. No-op in safe mode / off-Windows.
  ///
  /// NOTE: deliberately does NOT call setFullScreen(false). Leaving the window
  /// full-screen (just minimized + not-always-on-top) means that when the grant
  /// expires and the overlay must re-arm, the window snaps straight back to the
  /// full overlay instead of restoring as a small floating window first.
  Future<void> _minimizeOutOfTheWay() async {
    if (AppConfig.simulateLockdown || !Platform.isWindows) return;
    try {
      await windowManager.setAlwaysOnTop(false);
      await windowManager.minimize();
    } catch (_) {}
  }

  /// Block+minimize / allow a distraction at the guardian's request. NEVER
  /// kills a process — only minimizes its windows (or stops doing so). Non-fatal
  /// to the chat: the conversation stays live.
  Future<void> _onControlApp(String identifier, String action) async {
    if (identifier.trim().isEmpty) return;
    if (action == 'allow') {
      // "allow" is advisory here: the native foreground reclaim only minimizes
      // NON-allowed windows during a selective grant. Nothing to do in full
      // lock; the guardian's message already told the user.
      return;
    }
    // 'minimize' (and normalized 'block'): push the distraction out of the way.
    await WindowsLockdown.minimizeApp(identifier);
  }

  Future<void> _onMinimize(int minutes) async {
    // Use the guardian's real granted minutes (fall back to a small default if
    // the model omitted a duration). Previously hardcoded to 30 (M1 note).
    final grantMinutes = minutes > 0 ? minutes : AppConfig.minGrantedMinutes;
    widget.scheduler.grantExtension(grantMinutes);
    await WindowsLockdown.deactivate();
    if (Platform.isWindows && !AppConfig.simulateLockdown) {
      try {
        await windowManager.minimize();
      } catch (_) {}
    }
  }

  /// Selective per-app unlock: keep the overlay armed but allow [identifier]
  /// (a friendly name, package, or image name) for [minutes].
  ///
  /// On Windows, resolution to an image name happens in [WindowsLockdown] via
  /// the scheduler's onSelectiveGrant. On Android, the identifier is resolved to
  /// a package against the installed-app catalog and added to the native
  /// time-limited allow-list — but ONLY if it is on the user-approved
  /// negotiable-apps list (the guardian cannot free arbitrary apps).
  Future<void> _onUnlockApp(String identifier, int minutes) async {
    final grantMinutes = minutes > 0 ? minutes : AppConfig.minGrantedMinutes;

    if (Platform.isAndroid) {
      await _onUnlockAppAndroid(identifier, grantMinutes);
      return;
    }

    await _onUnlockAppWindows(identifier, grantMinutes);
  }

  /// The guardian asked to unlock an app that isn't on the user-approved
  /// negotiable-app list (or couldn't be resolved / armed). DENY it — do NOT
  /// fall back to a full grant. The old behavior freed the WHOLE machine when
  /// the store was empty, which is the exact opposite of a selective unlock and
  /// let any string become a full-device escape. We keep the overlay locked and
  /// tell the user why.
  void _denyUnlockApp(String identifier) {
    if (!mounted) return;
    setState(() => _grantedAppLabel = null);
    ScaffoldMessenger.maybeOf(context)?.showSnackBar(
      SnackBar(
        content: Text(
          identifier.trim().isEmpty
              ? "can't unlock that — it's not on your approved app list."
              : "can't unlock \"$identifier\" — add it to your negotiable apps "
                  "in settings first.",
        ),
        duration: const Duration(seconds: 3),
      ),
    );
  }

  Future<void> _onUnlockAppWindows(String identifier, int minutes) async {
    // Gate on the user-approved negotiable-app set exactly like Android: the
    // guardian may only selectively unlock apps the user explicitly approved in
    // Settings. Without this gate WindowsAppResolver would turn ANY string into
    // an `<input>.exe` and free an arbitrary process.
    final approved = NegotiableAppStore.instance.resolve(identifier);
    if (approved == null) {
      // Not on the approved list (or unresolvable). DENY — never free the whole
      // machine as a "fallback".
      _denyUnlockApp(identifier);
      return;
    }

    // Resolve the approved app's identifiers to Windows image name(s) for the
    // overlay allow-list. Prefer the stored package (the user may have entered
    // an image name there); fall back to the friendly label.
    final allow = WindowsAppResolver.resolveAll([approved.package, approved.label]);
    if (allow.isEmpty) {
      _denyUnlockApp(identifier);
      return;
    }
    widget.scheduler.grantSelective(allow: allow, minutes: minutes);
    setState(() => _showChat = false);
  }

  Future<void> _onUnlockAppAndroid(String identifier, int minutes) async {
    // Constrain to the user-approved negotiable-apps set: the guardian can only
    // unlock apps the user explicitly added in Settings.
    final resolved = NegotiableAppStore.instance.resolve(identifier);
    if (resolved == null) {
      // Not on the approved negotiable-apps list (or unresolvable). DENY rather
      // than freeing the whole device.
      _denyUnlockApp(identifier);
      return;
    }
    final ok = await AndroidLockdown.allowApp(
      package: resolved.package,
      minutes: minutes,
      label: resolved.label,
    );
    if (!mounted) return;
    if (!ok) {
      _denyUnlockApp(identifier);
      return;
    }
    widget.scheduler.grantSelective(allow: [resolved.package], minutes: minutes);
    setState(() {
      _grantedAppLabel = resolved.label;
      _showChat = false;
    });
  }

  /// Safe word + guardian `close`. Releases the lockdown fully and gets the app
  /// OUT OF THE WAY — but keeps it running in the background so it can still
  /// enforce future nights (a sleep guardian that quits is useless). The safe
  /// word must always reach here: fullUnlock clears the manual lock + grants and
  /// deactivate() tears down the platform takeover (fullscreen / always-on-top /
  /// key hook / watchdog).
  Future<void> _onClose() async {
    widget.scheduler.fullUnlock();
    await WindowsLockdown.deactivate();
    if (Platform.isWindows && !AppConfig.simulateLockdown) {
      try {
        await windowManager.setPreventClose(false);
      } catch (_) {}
    }
    if (mounted) {
      Navigator.of(context).pushAndRemoveUntil(
        MaterialPageRoute(builder: (_) => const HomeScreen()),
        (_) => false,
      );
    }
    // Drop to the taskbar so the guardian stays alive without covering the screen.
    await _minimizeOutOfTheWay();
  }

  void _onUnlock() {
    widget.scheduler.fullUnlock();
    WindowsLockdown.deactivate();
    if (mounted) {
      Navigator.of(context).pushAndRemoveUntil(
        MaterialPageRoute(builder: (_) => const HomeScreen()),
        (_) => false,
      );
    }
  }

  /// "Back to sleep early" from the granted view: END the active grant and
  /// RETURN to the locked overlay — this is NOT a full unlock for the night.
  /// [endGrantEarly] clears the grant without setting permanentlyUnlocked and
  /// recomputes to `locked`, which fires onStateChange → _syncPlatformLockdown
  /// → WindowsLockdown.activate() so the takeover re-arms. We drop the per-app
  /// label so the overlay no longer shows the borrowed app as unlocked.
  void _onEndGrantEarly() {
    if (mounted) {
      setState(() => _grantedAppLabel = null);
    } else {
      _grantedAppLabel = null;
    }
    widget.scheduler.endGrantEarly();
  }

  /// The engine already applied the schedule change (through the guardrails and
  /// ScheduleStore) before returning, so we only need to refresh the UI — the
  /// schedule card and unlock-time text rebuild via ScheduleStore listeners.
  void _onAdjustSchedule(GuardianDecision decision) {
    if (mounted) setState(() {});
  }

  @override
  Future<void> onWindowClose() async {
    if (AppConfig.simulateLockdown) return;
    if (widget.scheduler.state == LockdownState.locked) {
      await windowManager.focus();
      return;
    }
    await windowManager.destroy();
  }

  @override
  Future<void> onWindowBlur() async {
    if (AppConfig.simulateLockdown) return;
    if (!WindowsLockdown.isLocked) return;
    // While the chat is open, DON'T fight blur with show()/focus()/alwaysOnTop:
    // those reset the window's input chain and the chat TextField loses focus
    // (typing gets eaten). The native foreground reclaim already keeps us on
    // top; here we just leave the chat's keyboard focus intact.
    if (_showChat) return;
    await Future.delayed(const Duration(milliseconds: 50));
    try {
      await windowManager.show();
      await windowManager.focus();
      await windowManager.setAlwaysOnTop(true);
    } catch (_) {}
  }

  @override
  Future<void> onWindowFocus() async {
    if (AppConfig.simulateLockdown) return;
    if (!WindowsLockdown.isLocked) return;
    // We regained foreground (e.g. after the native reclaim minimized a foreign
    // window). If the chat is open, re-request keyboard focus for its TextField
    // so the user can keep typing — this is the recovery half of the
    // typing-eaten fix.
    if (_showChat) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted && _showChat) _chatFocusNode.requestFocus();
      });
    }
  }

  @override
  Future<void> onWindowMinimize() async {
    if (AppConfig.simulateLockdown) return;
    if (!WindowsLockdown.isLocked) return;
    try {
      await windowManager.restore();
      await windowManager.focus();
    } catch (_) {}
  }

  @override
  Widget build(BuildContext context) {
    // No app-level KeyboardListener / forced focus node here anymore. It used to
    // grab focus on build and compete with the chat TextField (typing got
    // eaten). Esc / Alt+F4 / Win etc. are already blocked NATIVELY by the
    // low-level keyboard hook in flutter_window.cpp, so the Flutter-side
    // listener was redundant as well as harmful.
    return PopScope(
      canPop: false,
      child: Scaffold(
        backgroundColor: const Color(0xFF0D0D1A),
        body: SafeArea(child: _buildContent()),
      ),
    );
  }

  Widget _buildContent() {
    if (widget.scheduler.state == LockdownState.granted) {
      return _buildGrantedView();
    }
    if (_showChat) return _buildChatView();
    return _buildLockedView();
  }

  void _openSettings() {
    Navigator.push(
      context,
      MaterialPageRoute(builder: (_) => const SettingsScreen()),
    );
  }

  Widget _buildLockedView() {
    return Stack(
      children: [
        if (AppConfig.simulateLockdown)
          Positioned(
            top: 16,
            left: 0,
            right: 0,
            child: Center(
              child: Container(
                padding:
                    const EdgeInsets.symmetric(horizontal: 14, vertical: 6),
                decoration: BoxDecoration(
                  color: const Color(0xFFFF9500).withAlpha(40),
                  borderRadius: BorderRadius.circular(20),
                  border: Border.all(
                    color: const Color(0xFFFF9500).withAlpha(120),
                  ),
                ),
                child: const Text(
                  'SAFE MODE — simulated lockdown',
                  style: TextStyle(
                    color: Color(0xFFFF9500),
                    fontSize: 11,
                    letterSpacing: 1.2,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ),
            ),
          ),
        // Guardian-offline banner: when no API key is configured the guardian
        // can't actually negotiate, so tell the user and point them at Settings
        // (reachable without escaping the lockdown via the gear below / header).
        if (!AppConfig.hasUsableAiKey)
          Positioned(
            top: AppConfig.simulateLockdown ? 48 : 16,
            left: 24,
            right: 24,
            child: GestureDetector(
              onTap: _openSettings,
              child: Container(
                padding:
                    const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
                decoration: BoxDecoration(
                  color: const Color(0xFFFF9500).withAlpha(28),
                  borderRadius: BorderRadius.circular(14),
                  border:
                      Border.all(color: const Color(0xFFFF9500).withAlpha(90)),
                ),
                child: const Row(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    Icon(Icons.cloud_off_rounded,
                        size: 16, color: Color(0xFFFFB95E)),
                    SizedBox(width: 8),
                    Flexible(
                      child: Text(
                        'Guardian offline — tap to configure your API key',
                        style: TextStyle(
                          color: Color(0xFFFFB95E),
                          fontSize: 12,
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
        Center(
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
          AnimatedBuilder(
            animation: _pulseController,
            builder: (context, child) => Opacity(
              opacity: 0.4 + (_pulseController.value * 0.6),
              child: const Icon(
                Icons.nights_stay_rounded,
                size: 72,
                color: Color(0xFF5B5FEF),
              ),
            ),
          ),
          const SizedBox(height: 32),
          StreamBuilder(
            stream: Stream.periodic(const Duration(seconds: 1)),
            builder: (context, _) {
              final now = DateTime.now();
              return Text(
                '${now.hour.toString().padLeft(2, '0')}:${now.minute.toString().padLeft(2, '0')}',
                style: const TextStyle(
                  color: Colors.white,
                  fontSize: 56,
                  fontWeight: FontWeight.w200,
                  letterSpacing: 6,
                ),
              );
            },
          ),
          const SizedBox(height: 8),
          Text(
            'Lockdown active',
            style: TextStyle(
              color: Colors.white.withAlpha(80),
              fontSize: 14,
              letterSpacing: 3,
            ),
          ),
          const SizedBox(height: 8),
          ListenableBuilder(
            listenable: ScheduleStore.instance,
            builder: (context, _) => Text(
              'Unlocks at ${AppConfig.formatTime(AppConfig.unlockHour, AppConfig.unlockMinute)}',
              style: TextStyle(
                color: Colors.white.withAlpha(40),
                fontSize: 12,
              ),
            ),
          ),
          const SizedBox(height: 56),
          GestureDetector(
            onTap: () => setState(() => _showChat = true),
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 28, vertical: 14),
              decoration: BoxDecoration(
                borderRadius: BorderRadius.circular(14),
                border: Border.all(color: Colors.white.withAlpha(20)),
                color: Colors.white.withAlpha(8),
              ),
              child: Text(
                'Negotiate',
                style: TextStyle(
                  color: Colors.white.withAlpha(100),
                  fontSize: 15,
                  letterSpacing: 1,
                ),
              ),
            ),
          ),
        ],
      ),
        ),
        Positioned(
          bottom: 24,
          right: 24,
          child: GestureDetector(
            onTap: _openSettings,
            child: Icon(
              Icons.settings_rounded,
              color: Colors.white.withAlpha(30),
              size: 20,
            ),
          ),
        ),
      ],
    );
  }

  Widget _buildChatView() {
    // Tell the engine whether we're inside lockdown so the guardrails can
    // forbid the AI from moving tonight's lockdown once it has started. The
    // chat is reachable from both locked and granted states.
    _engine.lockdownActive = widget.scheduler.state == LockdownState.locked ||
        widget.scheduler.state == LockdownState.granted;
    return Column(
      children: [
        Container(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
          decoration: BoxDecoration(
            border: Border(
              bottom: BorderSide(color: Colors.white.withAlpha(12)),
            ),
          ),
          child: Row(
            children: [
              GestureDetector(
                onTap: () => setState(() => _showChat = false),
                child: Icon(
                  Icons.arrow_back_rounded,
                  color: Colors.white.withAlpha(100),
                  size: 22,
                ),
              ),
              const SizedBox(width: 12),
              Container(
                width: 32,
                height: 32,
                decoration: BoxDecoration(
                  color: const Color(0xFF5B5FEF).withAlpha(40),
                  borderRadius: BorderRadius.circular(10),
                ),
                child: const Icon(
                  Icons.nights_stay_rounded,
                  color: Color(0xFF5B5FEF),
                  size: 16,
                ),
              ),
              const SizedBox(width: 10),
              Text(
                'Sleep Guardian',
                style: TextStyle(
                  color: Colors.white.withAlpha(200),
                  fontSize: 16,
                  fontWeight: FontWeight.w500,
                ),
              ),
              const Spacer(),
              // Settings shortcut INSIDE the chat header so a user trapped
              // behind a missing API key can configure it without escaping the
              // lockdown (pushes SettingsScreen on top of the overlay).
              GestureDetector(
                onTap: _openSettings,
                child: Icon(
                  Icons.settings_rounded,
                  color: Colors.white.withAlpha(90),
                  size: 20,
                ),
              ),
            ],
          ),
        ),
        Expanded(
          child: NegotiationChat(
            engine: _engine,
            grantsUsedTonight: widget.scheduler.grantsUsedTonight,
            grantActive: widget.scheduler.state == LockdownState.granted,
            inputFocusNode: _chatFocusNode,
            onGranted: _onGranted,
            onMinimize: _onMinimize,
            onClose: _onClose,
            onUnlock: _onUnlock,
            onUnlockApp: _onUnlockApp,
            onAdjustSchedule: _onAdjustSchedule,
            onControlApp: _onControlApp,
            onOpenSettings: _openSettings,
          ),
        ),
      ],
    );
  }

  Widget _buildGrantedView() {
    final perApp = _grantedAppLabel != null;
    return SafeArea(
      child: StreamBuilder(
        stream: Stream.periodic(const Duration(seconds: 1)),
        builder: (context, _) {
          final remaining = widget.scheduler.grantRemaining;
          // A per-app grant folds into a corner mini pill (the app is usable
          // behind it); a full grant folds to a corner mini countdown too, per
          // the "fold-to-corner countdown" spec.
          final size = OverlaySizing.select(
            locked: false,
            granted: true,
            perAppGrant: perApp,
            foldToCorner: true,
          );
          return Stack(
            children: [
              Positioned(
                top: 16,
                right: 16,
                child: OverlayShell(
                  size: size,
                  remaining: remaining,
                  appLabel: _grantedAppLabel,
                  onTapExpand: () => setState(() => _showChat = true),
                  onEndEarly: _onEndGrantEarly,
                ),
              ),
              // A gentle label so a full-screen grant view isn't just an empty
              // dark canvas with a corner pill.
              Center(
                child: Column(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    Icon(
                      perApp ? Icons.apps_rounded : Icons.timer_outlined,
                      size: 44,
                      color: const Color(0xFFFF9500),
                    ),
                    const SizedBox(height: 20),
                    Text(
                      perApp
                          ? '${_grantedAppLabel!} unlocked'
                          : 'Extension granted',
                      style: TextStyle(
                        color: Colors.white.withAlpha(140),
                        fontSize: 14,
                        letterSpacing: 2,
                      ),
                    ),
                  ],
                ),
              ),
            ],
          );
        },
      ),
    );
  }
}
