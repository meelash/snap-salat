import 'dart:convert';

import 'package:flutter/services.dart';
import 'package:http/http.dart' as http;
import 'package:shared_preferences/shared_preferences.dart';

import '../config.dart';
import '../models/masjid.dart';

/// The masjid directory: bundled with the app, refreshed from GitHub.
class RegistryService {
  static const _cacheKey = 'registry.cache';

  List<Masjid> _masajid = const [];
  List<Masjid> get masajid => _masajid;

  /// Loads the last downloaded copy, or the one bundled with the app.
  Future<void> loadLocal() async {
    final prefs = await SharedPreferences.getInstance();
    final cached = prefs.getString(_cacheKey);
    final text = cached ?? await rootBundle.loadString('assets/registry.json');
    _masajid = _parse(text);
  }

  /// Downloads the latest directory. Returns false if offline.
  Future<bool> refresh() async {
    try {
      final res = await http
          .get(AppConfig.registryUrl)
          .timeout(const Duration(seconds: 15));
      if (res.statusCode != 200) return false;
      final list = _parse(res.body);
      _masajid = list;
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(_cacheKey, res.body);
      return true;
    } catch (_) {
      return false;
    }
  }

  static List<Masjid> _parse(String text) {
    final j = jsonDecode(text) as Map<String, Object?>;
    return [
      for (final m in (j['masajid'] as List? ?? const []))
        Masjid.fromJson((m as Map).cast())
    ];
  }
}
