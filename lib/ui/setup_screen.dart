import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../core/config.dart';
import 'home_screen.dart';

/// First-run setup screen for provider selection / BYOK.
class SetupScreen extends StatefulWidget {
  const SetupScreen({super.key});

  @override
  State<SetupScreen> createState() => _SetupScreenState();
}

class _SetupScreenState extends State<SetupScreen> {
  final _geminiKeyController = TextEditingController();
  final _anthropicKeyController = TextEditingController();
  bool _loading = false;
  String? _error;
  AiProvider _provider = AiProvider.gemini;
  bool _useBringYourOwnKey = true;

  bool get _canContinue {
    if (_provider == AiProvider.gemini) {
      if (!_useBringYourOwnKey && AppConfig.conciergeGeminiApiKey.isNotEmpty) {
        return true;
      }
      return _geminiKeyController.text.trim().isNotEmpty;
    }
    return _anthropicKeyController.text.trim().isNotEmpty;
  }

  Future<void> _continue() async {
    if (!_canContinue) {
      setState(() {
        _error = _provider == AiProvider.gemini
            ? _useBringYourOwnKey
                ? 'Paste your Gemini API key to continue.'
                : 'This build does not include a Concierge Gemini key.'
            : 'Paste your Anthropic API key to continue.';
      });
      return;
    }

    setState(() {
      _loading = true;
      _error = null;
    });

    final prefs = await SharedPreferences.getInstance();
    await prefs.setString('ai_provider', _provider.name);
    await prefs.setBool('use_byok', _useBringYourOwnKey);
    await prefs.setString('gemini_api_key', _geminiKeyController.text.trim());
    await prefs.setString(
      'anthropic_api_key',
      _anthropicKeyController.text.trim(),
    );
    await prefs.setBool('setup_complete', true);

    AppConfig.aiProvider = _provider;
    AppConfig.useBringYourOwnKey = _useBringYourOwnKey;
    AppConfig.geminiApiKey = _geminiKeyController.text.trim();
    AppConfig.anthropicApiKey = _anthropicKeyController.text.trim();

    if (!mounted) return;

    Navigator.of(context).pushReplacement(
      MaterialPageRoute(builder: (_) => const HomeScreen()),
    );
  }

  @override
  void dispose() {
    _geminiKeyController.dispose();
    _anthropicKeyController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final hasConciergeGemini = AppConfig.conciergeGeminiApiKey.isNotEmpty;

    return Scaffold(
      backgroundColor: const Color(0xFFF0F4FA),
      body: SafeArea(
        child: Center(
          child: SingleChildScrollView(
            padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 24),
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 560),
              child: Column(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  const Icon(
                    Icons.nights_stay_rounded,
                    size: 64,
                    color: Color(0xFF5B5FEF),
                  ),
                  const SizedBox(height: 24),
                  const Text(
                    'Sleep Time',
                    style: TextStyle(
                      fontSize: 32,
                      fontWeight: FontWeight.w600,
                      color: Color(0xFF1A1A2E),
                      letterSpacing: -0.5,
                    ),
                  ),
                  const SizedBox(height: 8),
                  const Text(
                    'set up your sleep guardian',
                    style: TextStyle(fontSize: 15, color: Color(0xFF8E8EA0)),
                  ),
                  const SizedBox(height: 32),
                  Container(
                    width: double.infinity,
                    padding: const EdgeInsets.all(24),
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
                      children: [
                        const Text(
                          'AI setup',
                          style: TextStyle(
                            fontSize: 18,
                            fontWeight: FontWeight.w600,
                            color: Color(0xFF1A1A2E),
                          ),
                        ),
                        const SizedBox(height: 8),
                        const Text(
                          'Choose a provider and either use the bundled Concierge Gemini key or bring your own key.',
                          style: TextStyle(
                            fontSize: 13,
                            color: Color(0xFF8E8EA0),
                            height: 1.5,
                          ),
                        ),
                        const SizedBox(height: 20),
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
                            if (value == null) return;
                            setState(() {
                              _provider = value;
                              _error = null;
                            });
                          },
                        ),
                        const SizedBox(height: 12),
                        if (_provider == AiProvider.gemini) ...[
                          SwitchListTile.adaptive(
                            value: _useBringYourOwnKey,
                            contentPadding: EdgeInsets.zero,
                            title: const Text('Use my own Gemini key'),
                            subtitle: Text(
                              hasConciergeGemini
                                  ? _useBringYourOwnKey
                                      ? 'Your own Gemini key will be stored locally on this device.'
                                      : 'This build includes a Concierge Gemini key you can use by default.'
                                  : 'This build does not include a Concierge Gemini key, so BYOK is required.',
                            ),
                            onChanged: hasConciergeGemini
                                ? (value) {
                                    setState(() {
                                      _useBringYourOwnKey = value;
                                      _error = null;
                                    });
                                  }
                                : null,
                          ),
                          const SizedBox(height: 12),
                          _textField(
                            'Gemini API Key',
                            _geminiKeyController,
                            obscure: true,
                            enabled: _useBringYourOwnKey,
                          ),
                        ] else ...[
                          _textField(
                            'Anthropic API Key',
                            _anthropicKeyController,
                            obscure: true,
                          ),
                        ],
                        if (_error != null) ...[
                          const SizedBox(height: 12),
                          Text(
                            _error!,
                            style: const TextStyle(
                              color: Color(0xFFFF3B30),
                              fontSize: 13,
                            ),
                          ),
                        ],
                        const SizedBox(height: 20),
                        SizedBox(
                          width: double.infinity,
                          child: ElevatedButton(
                            onPressed: _loading ? null : _continue,
                            style: ElevatedButton.styleFrom(
                              backgroundColor: const Color(0xFF5B5FEF),
                              foregroundColor: Colors.white,
                              padding: const EdgeInsets.symmetric(vertical: 16),
                              shape: RoundedRectangleBorder(
                                borderRadius: BorderRadius.circular(14),
                              ),
                              elevation: 0,
                            ),
                            child: _loading
                                ? const SizedBox(
                                    width: 20,
                                    height: 20,
                                    child: CircularProgressIndicator(
                                      strokeWidth: 2,
                                      color: Colors.white,
                                    ),
                                  )
                                : const Text(
                                    'Continue',
                                    style: TextStyle(
                                      fontSize: 16,
                                      fontWeight: FontWeight.w600,
                                    ),
                                  ),
                          ),
                        ),
                      ],
                    ),
                  ),
                  const SizedBox(height: 16),
                  Text(
                    'Keys stay on this device. The selected provider only receives the messages needed to run the guardian.',
                    textAlign: TextAlign.center,
                    style: TextStyle(
                      fontSize: 11,
                      color: Colors.grey.shade500,
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
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
      onChanged: (_) {
        if (_error != null) {
          setState(() => _error = null);
        }
      },
      onSubmitted: (_) => _continue(),
    );
  }
}
