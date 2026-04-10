import 'dart:convert';
import 'package:http/http.dart' as http;
import 'config.dart';

/// Poke API integration for sending notifications/messages.
class PokeService {
  static const _baseUrl = 'https://poke.com/api/v1';

  static Future<bool> sendMessage(String message) async {
    if (AppConfig.pokeApiKey.isEmpty) return false;

    try {
      final response = await http.post(
        Uri.parse('$_baseUrl/inbound-sms/webhook'),
        headers: {
          'Authorization': 'Bearer ${AppConfig.pokeApiKey}',
          'Content-Type': 'application/json',
        },
        body: jsonEncode({'message': message}),
      );
      return response.statusCode >= 200 && response.statusCode < 300;
    } catch (_) {
      return false;
    }
  }

  /// Send a bedtime warning at 10:30 PM.
  static Future<void> sendBedtimeWarning() async {
    await sendMessage(
      '30 minutes until lockdown. wrap up what you\'re doing.',
    );
  }

  /// Notify when lockdown activates.
  static Future<void> sendLockdownActive() async {
    await sendMessage('lockdown active. goodnight.');
  }

  /// Notify when a grant is given.
  static Future<void> sendGrantNotification(int minutes) async {
    await sendMessage(
      'granted $minutes minutes. clock is ticking.',
    );
  }
}
