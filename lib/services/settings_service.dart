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

  // Persistent Cache
  Map<String, dynamic>? githubReleaseCache;
  DateTime? githubLastFetch;
  String? githubETag;
  Map<String, dynamic>? managerReleaseCache;
  DateTime? managerLastFetch;
  String? managerETag;


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
        
        // Load cache
        if (data['githubReleaseCache'] != null) {
          githubReleaseCache = Map<String, dynamic>.from(data['githubReleaseCache']);
        }
        if (data['githubLastFetch'] != null) {
          githubLastFetch = DateTime.parse(data['githubLastFetch']);
        }
        if (data['githubETag'] != null) {
          githubETag = data['githubETag'];
        }
        if (data['managerReleaseCache'] != null) {
          managerReleaseCache = Map<String, dynamic>.from(data['managerReleaseCache']);
        }
        if (data['managerLastFetch'] != null) {
          managerLastFetch = DateTime.parse(data['managerLastFetch']);
        }
        if (data['managerETag'] != null) {
          managerETag = data['managerETag'];
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
        'githubReleaseCache': githubReleaseCache,
        'githubLastFetch': githubLastFetch?.toIso8601String(),
        'githubETag': githubETag,
        'managerReleaseCache': managerReleaseCache,
        'managerLastFetch': managerLastFetch?.toIso8601String(),
        'managerETag': managerETag,

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
