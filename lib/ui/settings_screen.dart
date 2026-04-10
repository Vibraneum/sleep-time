import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../core/config.dart';

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

  late AiProvider _provider;
  late bool _useBringYourOwnKey;
  late TimeOfDay _wakeUpTime;
  late TimeOfDay _windDownTime;
  late TimeOfDay _lockdownTime;
  late TimeOfDay _unlockTime;
  bool _saved = false;

  @override
  void initState() {
    super.initState();
    _provider = AppConfig.aiProvider;
    _useBringYourOwnKey = AppConfig.useBringYourOwnKey;
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
  }

  Future<void> _save() async {
    final prefs = await SharedPreferences.getInstance();

    await prefs.setString('ai_provider', _provider.name);
    await prefs.setBool('use_byok', _useBringYourOwnKey);
    await prefs.setString('gemini_api_key', _geminiKeyController.text.trim());
    await prefs.setString(
      'anthropic_api_key',
      _anthropicKeyController.text.trim(),
    );
    await prefs.setString('poke_api_key', _pokeKeyController.text.trim());
    await prefs.setString('gemini_model', _geminiModelController.text.trim());
    await prefs.setString(
      'anthropic_model',
      _anthropicModelController.text.trim(),
    );
    await prefs.setInt('wakeup_hour', _wakeUpTime.hour);
    await prefs.setInt('wakeup_minute', _wakeUpTime.minute);
    await prefs.setInt('winddown_hour', _windDownTime.hour);
    await prefs.setInt('winddown_minute', _windDownTime.minute);
    await prefs.setInt('lockdown_hour', _lockdownTime.hour);
    await prefs.setInt('lockdown_minute', _lockdownTime.minute);
    await prefs.setInt('unlock_hour', _unlockTime.hour);
    await prefs.setInt('unlock_minute', _unlockTime.minute);

    AppConfig.aiProvider = _provider;
    AppConfig.useBringYourOwnKey = _useBringYourOwnKey;
    AppConfig.geminiApiKey = _geminiKeyController.text.trim();
    AppConfig.anthropicApiKey = _anthropicKeyController.text.trim();
    AppConfig.pokeApiKey = _pokeKeyController.text.trim();
    AppConfig.geminiModel = _geminiModelController.text.trim().isEmpty
        ? 'gemini-2.5-flash'
        : _geminiModelController.text.trim();
    AppConfig.anthropicModel = _anthropicModelController.text.trim().isEmpty
        ? 'claude-3-5-sonnet-latest'
        : _anthropicModelController.text.trim();
    AppConfig.wakeUpHour = _wakeUpTime.hour;
    AppConfig.wakeUpMinute = _wakeUpTime.minute;
    AppConfig.windDownHour = _windDownTime.hour;
    AppConfig.windDownMinute = _windDownTime.minute;
    AppConfig.lockdownHour = _lockdownTime.hour;
    AppConfig.lockdownMinute = _lockdownTime.minute;
    AppConfig.unlockHour = _unlockTime.hour;
    AppConfig.unlockMinute = _unlockTime.minute;

    if (!mounted) return;
    setState(() => _saved = true);
    Future.delayed(const Duration(seconds: 2), () {
      if (mounted) setState(() => _saved = false);
    });
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
            ]),
            const SizedBox(height: 16),
            _card([
              _sectionTitle('Platform + Notifications'),
              const SizedBox(height: 14),
              _textField('Poke API Key', _pokeKeyController, obscure: true),
              const SizedBox(height: 10),
              const Text(
                'Windows enforcement is best-effort: always-on-top, fullscreen, prevent-close, and taskbar hiding. Android uses device-admin and lock-task hooks where available.',
                style: TextStyle(
                  fontSize: 13,
                  color: Color(0xFF8E8EA0),
                  height: 1.5,
                ),
              ),
            ]),
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
