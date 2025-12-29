import 'dart:convert';
import 'dart:io';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

class SettingsService {
  static final SettingsService _instance = SettingsService._internal();
  factory SettingsService() => _instance;
  SettingsService._internal();

  String? lastLauncher;
  String? lastInstance;
  List<String> customPaths = [];

  Future<void> init() async {
    await loadSettings();
  }

  Future<File> _getSettingsFile() async {
    final directory = await getApplicationSupportDirectory();
    return File(p.join(directory.path, 'settings.json'));
  }

  Future<void> loadSettings() async {
    try {
      final file = await _getSettingsFile();
      if (await file.exists()) {
        final content = await file.readAsString();
        final data = json.decode(content);
        lastLauncher = data['lastLauncher'];
        lastInstance = data['lastInstance'];
        if (data['customPaths'] != null) {
          customPaths = List<String>.from(data['customPaths']);
        }
      }
    } catch (e) {
      print("[Settings] Error loading settings: $e");
    }
  }

  Future<void> saveSettings() async {
    try {
      final file = await _getSettingsFile();
      final data = {
        'lastLauncher': lastLauncher,
        'lastInstance': lastInstance,
        'customPaths': customPaths,
      };
      await file.writeAsString(json.encode(data));
    } catch (e) {
      print("[Settings] Error saving settings: $e");
    }
  }

  void addCustomPath(String path) {
    if (!customPaths.contains(path)) {
      customPaths.add(path);
      saveSettings();
    }
  }

  void removeCustomPath(String path) {
    if (customPaths.contains(path)) {
      customPaths.remove(path);
      saveSettings();
    }
  }
}
