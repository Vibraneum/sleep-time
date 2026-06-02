import 'dart:io';

import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../core/config.dart';
import '../core/schedule.dart';
import '../core/schedule_store.dart';
import '../core/secure_key_store.dart';
import '../platform/windows_lockdown.dart';
import 'allowlist_editor_screen.dart';
import 'permissions_onboarding_screen.dart';

class SettingsScreen extends StatefulWidget {
  const SettingsScreen({super.key});

  @override
  State<SettingsScreen> createState() => _SettingsScreenState();
}

class _SettingsScreenState extends State<SettingsScreen> {
  final _geminiKeyController = TextEditingController();
  final _anthropicKeyController = TextEditingController();
  final _pokeKeyController = TextEditingController();
  final _geminiModelController = TextEditingController();
  final _anthropicModelController = TextEditingController();
  final _safeWordController = TextEditingController();

  final _secureKeyStore = SecureKeyStore();

  late AiProvider _provider;
  late bool _useBringYourOwnKey;
  late bool _runAtStartup;
  late bool _simulateLockdown;
  late TimeOfDay _wakeUpTime;
  late TimeOfDay _windDownTime;
  late TimeOfDay _lockdownTime;
  late TimeOfDay _unlockTime;
  bool _saved = false;

  /// Inline validation errors for the schedule, surfaced as red helper text
  /// under the Schedule card. Populated on a blocked save.
  List<String> _scheduleErrors = const [];

  @override
  void initState() {
    super.initState();
    _provider = AppConfig.aiProvider;
    _useBringYourOwnKey = AppConfig.useBringYourOwnKey;
    _runAtStartup = AppConfig.runAtStartup;
    _simulateLockdown = AppConfig.simulateLockdown;
    _wakeUpTime =
        TimeOfDay(hour: AppConfig.wakeUpHour, minute: AppConfig.wakeUpMinute);
    _windDownTime = TimeOfDay(
      hour: AppConfig.windDownHour,
      minute: AppConfig.windDownMinute,
    );
    _lockdownTime = TimeOfDay(
      hour: AppConfig.lockdownHour,
      minute: AppConfig.lockdownMinute,
    );
    _unlockTime =
        TimeOfDay(hour: AppConfig.unlockHour, minute: AppConfig.unlockMinute);

    _geminiKeyController.text = AppConfig.geminiApiKey;
    _anthropicKeyController.text = AppConfig.anthropicApiKey;
    _pokeKeyController.text = AppConfig.pokeApiKey;
    _geminiModelController.text = AppConfig.geminiModel;
    _anthropicModelController.text = AppConfig.anthropicModel;
    _safeWordController.text = AppConfig.safeWord;
  }

  Future<void> _save() async {
    // Build + validate the proposed schedule first; block the save (with inline
    // red helper text) if it would be rejected by SleepSchedule.validate so we
    // never persist an invalid schedule.
    final proposed = SleepSchedule(
      wakeUp: ScheduleTime(_wakeUpTime.hour, _wakeUpTime.minute),
      windDown: ScheduleTime(_windDownTime.hour, _windDownTime.minute),
      lockdown: ScheduleTime(_lockdownTime.hour, _lockdownTime.minute),
      unlock: ScheduleTime(_unlockTime.hour, _unlockTime.minute),
    );
    final validation = proposed.validate();
    if (!validation.ok) {
      setState(() => _scheduleErrors = validation.violations);
      return;
    }

    // Human escape hatch: moving the unlock EARLIER while we're inside the
    // lockdown window would end the lock sooner than promised. Humans are
    // allowed to do this (the AI is not), but confirm it first. We use
    // AppConfig.isLockdownTime as the "currently locked" signal because the
    // settings screen has no scheduler reference; this also covers the granted
    // sub-state, which still falls inside the lockdown window.
    final currentUnlockMin = AppConfig.unlockHour * 60 + AppConfig.unlockMinute;
    final newUnlockMin = _unlockTime.hour * 60 + _unlockTime.minute;
    if (AppConfig.isLockdownTime(DateTime.now()) &&
        newUnlockMin < currentUnlockMin) {
      final confirmed = await _confirmEarlierUnlock();
      if (confirmed != true) return;
    }

    setState(() => _scheduleErrors = const []);

    final prefs = await SharedPreferences.getInstance();

    await prefs.setString('ai_provider', _provider.name);
    await prefs.setBool('use_byok', _useBringYourOwnKey);
    // API keys are written ONLY to encrypted-at-rest secure storage, never to
    // plaintext SharedPreferences.
    await _secureKeyStore.write(
      SecureKeyStore.geminiApiKey,
      _geminiKeyController.text.trim(),
    );
    await _secureKeyStore.write(
      SecureKeyStore.anthropicApiKey,
      _anthropicKeyController.text.trim(),
    );
    await _secureKeyStore.write(
      SecureKeyStore.pokeApiKey,
      _pokeKeyController.text.trim(),
    );
    await prefs.setString('gemini_model', _geminiModelController.text.trim());
    await prefs.setString(
      'anthropic_model',
      _anthropicModelController.text.trim(),
    );
    // Schedule writes funnel through ScheduleStore so the change persists,
    // validates, audits, and notifies live listeners. Already validated above.
    ScheduleStore.instance.apply(
      proposed,
      source: ScheduleSource.userSettings,
    );
    await prefs.setString('safe_word', _safeWordController.text.trim());
    await prefs.setBool('run_at_startup', _runAtStartup);
    await prefs.setBool('simulate_lockdown', _simulateLockdown);

    AppConfig.aiProvider = _provider;
    AppConfig.useBringYourOwnKey = _useBringYourOwnKey;
    AppConfig.geminiApiKey = _geminiKeyController.text.trim();
    AppConfig.anthropicApiKey = _anthropicKeyController.text.trim();
    AppConfig.pokeApiKey = _pokeKeyController.text.trim();
    AppConfig.geminiModel = _geminiModelController.text.trim().isEmpty
        ? 'gemini-2.5-flash'
        : _geminiModelController.text.trim();
    AppConfig.anthropicModel = _anthropicModelController.text.trim().isEmpty
        ? AppConfig.defaultAnthropicModel
        : _anthropicModelController.text.trim();
    // Schedule mirrored into ScheduleStore above via apply().
    AppConfig.safeWord = _safeWordController.text.trim();
    AppConfig.runAtStartup = _runAtStartup;
    AppConfig.simulateLockdown = _simulateLockdown;
    if (Platform.isWindows) {
      if (_runAtStartup && !_simulateLockdown) {
        await WindowsLockdown.registerStartup();
      } else {
        await WindowsLockdown.unregisterStartup();
      }
    }

    if (!mounted) return;
    setState(() => _saved = true);
    Future.delayed(const Duration(seconds: 2), () {
      if (mounted) setState(() => _saved = false);
    });
  }

  Future<bool?> _confirmEarlierUnlock() {
    return showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        backgroundColor: Colors.white,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(20),
        ),
        title: const Text(
          'End lockdown earlier?',
          style: TextStyle(
            fontSize: 18,
            fontWeight: FontWeight.w600,
            color: Color(0xFF1A1A2E),
          ),
        ),
        content: const Text(
          "You're currently in a lockdown window and moving the unlock time "
          'earlier. This will let you out sooner than the schedule promised. '
          'Continue?',
          style: TextStyle(fontSize: 14, color: Color(0xFF8E8EA0), height: 1.5),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: const Text(
              'Cancel',
              style: TextStyle(color: Color(0xFF8E8EA0)),
            ),
          ),
          TextButton(
            onPressed: () => Navigator.of(context).pop(true),
            child: const Text(
              'Unlock earlier',
              style: TextStyle(
                color: Color(0xFF5B5FEF),
                fontWeight: FontWeight.w600,
              ),
            ),
          ),
        ],
      ),
    );
  }

  Future<void> _pickTime(
    TimeOfDay current,
    void Function(TimeOfDay picked) onPicked,
  ) async {
    final picked = await showTimePicker(
      context: context,
      initialTime: current,
      builder: (context, child) => Theme(
        data: ThemeData.light().copyWith(
          colorScheme: const ColorScheme.light(primary: Color(0xFF5B5FEF)),
        ),
        child: child!,
      ),
    );
    if (picked != null && mounted) {
      setState(() => onPicked(picked));
    }
  }

  @override
  void dispose() {
    _geminiKeyController.dispose();
    _anthropicKeyController.dispose();
    _pokeKeyController.dispose();
    _geminiModelController.dispose();
    _anthropicModelController.dispose();
    _safeWordController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final usingConcierge = !_useBringYourOwnKey;
    final hasConciergeKey = AppConfig.conciergeGeminiApiKey.isNotEmpty;

    return Scaffold(
      backgroundColor: const Color(0xFFF0F4FA),
      appBar: AppBar(
        backgroundColor: Colors.transparent,
        elevation: 0,
        foregroundColor: const Color(0xFF1A1A2E),
        title: const Text(
          'Settings',
          style: TextStyle(fontWeight: FontWeight.w600, fontSize: 20),
        ),
      ),
      body: SingleChildScrollView(
        padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 8),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            _card([
              _sectionTitle('AI Provider'),
              const SizedBox(height: 14),
              DropdownButtonFormField<AiProvider>(
                initialValue: _provider,
                decoration: _inputDecoration('Provider'),
                items: const [
                  DropdownMenuItem(
                    value: AiProvider.gemini,
                    child: Text('Gemini'),
                  ),
                  DropdownMenuItem(
                    value: AiProvider.anthropic,
                    child: Text('Anthropic'),
                  ),
                ],
                onChanged: (value) {
                  if (value != null) setState(() => _provider = value);
                },
              ),
              const SizedBox(height: 12),
              SwitchListTile.adaptive(
                value: _useBringYourOwnKey,
                contentPadding: EdgeInsets.zero,
                title: const Text('Use my own Gemini key'),
                subtitle: Text(
                  usingConcierge
                      ? hasConciergeKey
                          ? 'Using the built-in Concierge Gemini key by default.'
                          : 'No Concierge Gemini key is bundled in this build.'
                      : 'Users can bring their own Gemini key.',
                ),
                onChanged: (value) {
                  setState(() => _useBringYourOwnKey = value);
                },
              ),
              const SizedBox(height: 12),
              _textField('Gemini model', _geminiModelController),
              const SizedBox(height: 12),
              _textField(
                'Gemini API Key',
                _geminiKeyController,
                obscure: true,
                enabled: _useBringYourOwnKey,
              ),
              const SizedBox(height: 12),
              _textField('Anthropic model', _anthropicModelController),
              const SizedBox(height: 12),
              _textField(
                'Anthropic API Key',
                _anthropicKeyController,
                obscure: true,
              ),
            ]),
            const SizedBox(height: 16),
            _card([
              _sectionTitle('Schedule'),
              const SizedBox(height: 14),
              _timeRow('Guardian wakes', _wakeUpTime, (t) => _wakeUpTime = t),
              _timeRow('Wind down', _windDownTime, (t) => _windDownTime = t),
              _timeRow('Lockdown', _lockdownTime, (t) => _lockdownTime = t),
              _timeRow('Unlock', _unlockTime, (t) => _unlockTime = t),
              if (_scheduleErrors.isNotEmpty) ...[
                const SizedBox(height: 8),
                for (final err in _scheduleErrors)
                  Padding(
                    padding: const EdgeInsets.only(top: 4),
                    child: Text(
                      err,
                      style: const TextStyle(
                        fontSize: 12,
                        color: Color(0xFFFF3B30),
                      ),
                    ),
                  ),
              ],
            ]),
            const SizedBox(height: 16),
            _card([
              _sectionTitle('Safe Word'),
              const SizedBox(height: 10),
              const Text(
                'Set a secret word that instantly unlocks the app during lockdown. '
                'Give it to a family member so they can override the lockdown if needed. '
                'Leave blank to disable.',
                style: TextStyle(
                  fontSize: 13,
                  color: Color(0xFF8E8EA0),
                  height: 1.5,
                ),
              ),
              const SizedBox(height: 12),
              _textField('Safe word', _safeWordController, obscure: true),
            ]),
            const SizedBox(height: 16),
            _card([
              _sectionTitle('Platform + Notifications'),
              const SizedBox(height: 14),
              SwitchListTile.adaptive(
                value: _simulateLockdown,
                contentPadding: EdgeInsets.zero,
                title: const Text('Safe mode (simulate lockdown)'),
                subtitle: const Text(
                  'Walk through the full lockdown UI without any platform side effects — '
                  'no fullscreen takeover, no always-on-top, no Android kiosk. '
                  'Recommended while developing or trying the app for the first time.',
                ),
                onChanged: (value) =>
                    setState(() => _simulateLockdown = value),
              ),
              const SizedBox(height: 12),
              if (Platform.isWindows)
                SwitchListTile.adaptive(
                  value: _runAtStartup,
                  contentPadding: EdgeInsets.zero,
                  title: const Text('Launch at login'),
                  subtitle: Text(
                    _simulateLockdown
                        ? 'Disabled while safe mode is on.'
                        : 'Start Sleep Time automatically when you log into Windows.',
                  ),
                  onChanged: _simulateLockdown
                      ? null
                      : (value) => setState(() => _runAtStartup = value),
                ),
              if (Platform.isWindows) const SizedBox(height: 12),
              _textField('Poke API Key', _pokeKeyController, obscure: true),
              const SizedBox(height: 10),
              const Text(
                'Windows enforcement is best-effort: always-on-top, fullscreen, prevent-close, and taskbar hiding. Android shows a Play-compliant lock overlay over blocked apps, using usage access to see which app is in front (with an optional accessibility helper for faster reactions). It never uses device-admin or kiosk lock-task.',
                style: TextStyle(
                  fontSize: 13,
                  color: Color(0xFF8E8EA0),
                  height: 1.5,
                ),
              ),
            ]),
            if (Platform.isAndroid) ...[
              const SizedBox(height: 16),
              _card([
                _sectionTitle('Android'),
                const SizedBox(height: 10),
                const Text(
                  'Manage the permissions the background guardian needs, and '
                  'choose which apps the guardian is allowed to unlock during '
                  'lockdown.',
                  style: TextStyle(
                      fontSize: 13, color: Color(0xFF8E8EA0), height: 1.5),
                ),
                const SizedBox(height: 12),
                _navTile(
                  Icons.shield_outlined,
                  'Permissions',
                  'Notifications, overlay, usage access, alarms, battery',
                  () => Navigator.push(
                    context,
                    MaterialPageRoute(
                      builder: (_) => PermissionsOnboardingScreen(
                        onComplete: () => Navigator.of(context).pop(),
                      ),
                    ),
                  ),
                ),
                const SizedBox(height: 8),
                _navTile(
                  Icons.apps_rounded,
                  'Apps the guardian can unlock',
                  'Opt in the apps the guardian may free during lockdown',
                  () => Navigator.push(
                    context,
                    MaterialPageRoute(
                      builder: (_) => const AllowlistEditorScreen(),
                    ),
                  ),
                ),
              ]),
            ],
            const SizedBox(height: 16),
            _card([
              _sectionTitle('Guardian policy'),
              const SizedBox(height: 10),
              const Text(
                'The guardian decides grants dynamically, but the app still clamps extension lengths to a safe range so a bad model response cannot unlock the machine for absurd amounts of time.',
                style: TextStyle(
                  fontSize: 13,
                  color: Color(0xFF8E8EA0),
                  height: 1.5,
                ),
              ),
            ]),
            const SizedBox(height: 24),
            SizedBox(
              width: double.infinity,
              child: ElevatedButton(
                onPressed: _save,
                style: ElevatedButton.styleFrom(
                  backgroundColor:
                      _saved ? const Color(0xFF34C759) : const Color(0xFF5B5FEF),
                  foregroundColor: Colors.white,
                  padding: const EdgeInsets.symmetric(vertical: 16),
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(14),
                  ),
                  elevation: 0,
                ),
                child: Text(
                  _saved ? 'Saved' : 'Save settings',
                  style: const TextStyle(
                    fontSize: 16,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ),
            ),
            const SizedBox(height: 32),
          ],
        ),
      ),
    );
  }

  Widget _card(List<Widget> children) {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(20),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(20),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withAlpha(8),
            blurRadius: 20,
            offset: const Offset(0, 4),
          ),
        ],
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: children,
      ),
    );
  }

  Widget _navTile(
    IconData icon,
    String title,
    String subtitle,
    VoidCallback onTap,
  ) {
    return InkWell(
      borderRadius: BorderRadius.circular(12),
      onTap: onTap,
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 6),
        child: Row(
          children: [
            Container(
              width: 40,
              height: 40,
              decoration: BoxDecoration(
                color: const Color(0xFF5B5FEF).withAlpha(24),
                borderRadius: BorderRadius.circular(12),
              ),
              child: Icon(icon, color: const Color(0xFF5B5FEF), size: 22),
            ),
            const SizedBox(width: 14),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(title,
                      style: const TextStyle(
                          fontSize: 15,
                          fontWeight: FontWeight.w500,
                          color: Color(0xFF1A1A2E))),
                  Text(subtitle,
                      style: const TextStyle(
                          fontSize: 12, color: Color(0xFF8E8EA0))),
                ],
              ),
            ),
            const Icon(Icons.chevron_right_rounded, color: Color(0xFF8E8EA0)),
          ],
        ),
      ),
    );
  }

  Widget _sectionTitle(String text) {
    return Text(
      text,
      style: const TextStyle(
        fontSize: 13,
        fontWeight: FontWeight.w600,
        color: Color(0xFF8E8EA0),
        letterSpacing: 0.5,
      ),
    );
  }

  InputDecoration _inputDecoration(String label) {
    return InputDecoration(
      labelText: label,
      labelStyle: const TextStyle(color: Color(0xFF8E8EA0), fontSize: 13),
      enabledBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(12),
        borderSide: const BorderSide(color: Color(0xFFE5E5EA)),
      ),
      focusedBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(12),
        borderSide: const BorderSide(color: Color(0xFF5B5FEF)),
      ),
      disabledBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(12),
        borderSide: const BorderSide(color: Color(0xFFE5E5EA)),
      ),
      filled: true,
      fillColor: const Color(0xFFF8F8FC),
      contentPadding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
    );
  }

  Widget _textField(
    String label,
    TextEditingController controller, {
    bool obscure = false,
    bool enabled = true,
  }) {
    return TextField(
      controller: controller,
      obscureText: obscure,
      enabled: enabled,
      style: const TextStyle(fontSize: 14, color: Color(0xFF1A1A2E)),
      decoration: _inputDecoration(label),
    );
  }

  Widget _timeRow(
    String label,
    TimeOfDay time,
    void Function(TimeOfDay picked) onPicked,
  ) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        children: [
          Text(
            label,
            style: const TextStyle(fontSize: 15, color: Color(0xFF1A1A2E)),
          ),
          GestureDetector(
            onTap: () => _pickTime(time, onPicked),
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
              decoration: BoxDecoration(
                color: const Color(0xFFF0F0F5),
                borderRadius: BorderRadius.circular(8),
              ),
              child: Text(
                AppConfig.formatTime(time.hour, time.minute),
                style: const TextStyle(
                  fontSize: 15,
                  fontWeight: FontWeight.w500,
                  color: Color(0xFF5B5FEF),
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}
