import 'dart:convert';
import 'package:http/http.dart' as http;
import 'package:flutter/foundation.dart';
import 'settings_service.dart';

class GithubRelease {
  final String tag;
  final String downloadUrl;
  final String manifestUrl;
  final String mrpackUrl;
  final String body;

  GithubRelease({
    required this.tag, 
    required this.downloadUrl, 
    required this.manifestUrl, 
    required this.mrpackUrl, 
    required this.body
  });

  factory GithubRelease.fromJson(Map<String, dynamic> json) {
    final tag = json['tag_name'] ?? '0.0.0';
    final body = json['body'] ?? '';
    String downloadUrl = '';
    String manifestUrl = '';
    String mrpackUrl = '';

    print("[GithubService] Parsing release assets for tag $tag...");
    if (json['assets'] != null) {
      for (var asset in json['assets']) {
        final name = asset['name'].toString().toLowerCase();
        print("[GithubService] Checking asset: $name");
        if (name.endsWith('.zip')) {
          downloadUrl = asset['browser_download_url'] ?? '';
        } else if (name == 'manifest.json') {
          manifestUrl = asset['browser_download_url'] ?? '';
        } else if (name.endsWith('.mrpack')) {
          mrpackUrl = asset['browser_download_url'] ?? '';
        }
      }
    }

    // Fallback: If no manifest.json asset, try to extract from body
    // If body contains a JSON block with "fabric": "..."
    if (manifestUrl.isEmpty && body.contains('"fabric"')) {
      print("[GithubService] Fallback: Found potential manifest in body");
      // We'll mark a special flag or just handle it in the Service
    }

    return GithubRelease(
      tag: tag, 
      downloadUrl: downloadUrl, 
      manifestUrl: manifestUrl, 
      mrpackUrl: mrpackUrl, 
      body: body
    );
  }
}

class GithubService {
  final String owner = 'Ciobert345';
  final String repo = 'Mod-server-Manfredonia';
  
  // PASTE YOUR GITHUB TOKEN HERE
  static const String _apiToken = ""; 

  // Simple in-memory cache
  GithubRelease? _cachedRelease;
  DateTime? _lastFetch;
  final Duration _cacheTTL = const Duration(minutes: 15); // Increased TTL


  Future<GithubRelease?> getLatestRelease() async {
    final settings = SettingsService();

    // 1. Check in-memory cache
    if (_cachedRelease != null && _lastFetch != null) {
      if (DateTime.now().difference(_lastFetch!) < _cacheTTL) {
        print("[GithubService] Returning in-memory cached release info (TTL: ${DateTime.now().difference(_lastFetch!).inSeconds}s)");
        return _cachedRelease;
      }
    }

    // 2. Check persistent cache from SettingsService
    if (settings.githubReleaseCache != null && settings.githubLastFetch != null) {
      if (DateTime.now().difference(settings.githubLastFetch!) < _cacheTTL) {
        print("[GithubService] Returning persistent cached release info: ${settings.githubReleaseCache?['tag_name']}");
        _cachedRelease = GithubRelease.fromJson(settings.githubReleaseCache!);
        _lastFetch = settings.githubLastFetch;
        return _cachedRelease;
      }
    }


    final url = Uri.parse('https://api.github.com/repos/$owner/$repo/releases/latest');
    
    try {
      print("[GithubService] Fetching latest release from GitHub API...");
      final headers = {
        'User-Agent': 'ManfredoniaManager-Flutter',
        'Accept': 'application/vnd.github.v3+json',
      };
      
      final token = kDebugMode ? _apiToken : "";
      if (token.isNotEmpty) {
        print("[GithubService] Using Personal Access Token for request (DEBUG MODE)");
        headers['Authorization'] = 'token $token';
      }

      final response = await http.get(url, headers: headers).timeout(const Duration(seconds: 10));

      if (response.statusCode == 200) {
        final parsed = json.decode(response.body);
        _cachedRelease = GithubRelease.fromJson(parsed);
        _lastFetch = DateTime.now();

        // Update persistent cache
        settings.githubReleaseCache = parsed;
        settings.githubLastFetch = _lastFetch;
        await settings.saveSettings();

        return _cachedRelease;
      } else if (response.statusCode == 403) {
        print("[GithubService] RATE LIMIT EXCEEDED or Forbidden. Trying fallback.");
        
        final tag = await _getLatestTagFromRedirect();
        if (tag != null) {
          final zipUrl = _buildAssetUrl(tag, '.zip');
          final manifestUrl = _buildAssetUrl(tag, 'manifest.json');
          final mrpackUrl = _buildAssetUrl(tag, '.mrpack');

          final fallbackData = {
            'tag_name': tag,
            'body': '',
            'assets': [
              if (zipUrl != null) {'name': 'modpack.zip', 'browser_download_url': zipUrl},
              if (manifestUrl != null) {'name': 'manifest.json', 'browser_download_url': manifestUrl},
              if (mrpackUrl != null) {'name': 'modpack.mrpack', 'browser_download_url': mrpackUrl},
            ]
          };

          _cachedRelease = GithubRelease.fromJson(fallbackData);
          _lastFetch = DateTime.now();

          // Update persistent cache
          settings.githubReleaseCache = fallbackData;
          settings.githubLastFetch = _lastFetch;
          await settings.saveSettings();

          return _cachedRelease;
        }

        return _cachedRelease; // Return stale cache if fallback fails
      }
      
      print("[GithubService] GitHub API returned status: ${response.statusCode}");
      return _cachedRelease; // Return stale cache if API fails

    } catch (e) {
      print('Error checking GitHub: $e');
      return _cachedRelease;
    }
  }

  Future<Map<String, dynamic>?> getManifest(String url, {String? fallbackBody}) async {
    if (url.isNotEmpty) {
      try {
        final response = await http.get(Uri.parse(url)).timeout(const Duration(seconds: 10));
        if (response.statusCode == 200) {
          return json.decode(response.body);
        }
      } catch (e) {
        print('Error fetching manifest: $e');
      }
    }

    // Try fallback from body if provided
    if (fallbackBody != null && (fallbackBody.contains('"fabric"') || fallbackBody.contains('fabric:'))) {
      try {
        print("[GithubService] Attempting to extract manifest from body fallback");
        // Try to find a JSON block: { ... "fabric": "..." ... }
        final jsonRegExp = RegExp(r'\{[\s\S]*"fabric"[\s\S]*\}');
        final jsonMatch = jsonRegExp.firstMatch(fallbackBody);
        if (jsonMatch != null) {
          return json.decode(jsonMatch.group(0)!);
        }

        // Try to find individual lines like "fabric: 0.16.10" or "fabric: 0.16.10"
        final fabricMatch = RegExp(r'fabric[:"]\s*"?([0-9.]+)"?').firstMatch(fallbackBody);
        if (fabricMatch != null) {
          final version = fabricMatch.group(1);
          print("[GithubService] Extracted fabric version from body text: $version");
          return {'fabric': version};
        }
      } catch (e) {
        print("[GithubService] Error extracting manifest from body: $e");
      }
    }
    
    return null;
  }

  Future<String?> _getLatestTagFromRedirect() async {
    final url = Uri.parse('https://github.com/$owner/$repo/releases/latest');
    try {
      final client = http.Client();
      final request = http.Request('GET', url)..followRedirects = false;
      request.headers['User-Agent'] = 'ManfredoniaManager-Flutter';
      
      final response = await client.send(request).timeout(const Duration(seconds: 10));
      final location = response.headers['location'];
      if (location == null || location.isEmpty) return null;

      final segments = Uri.parse(location).pathSegments;
      if (segments.contains('tag')) {
        return segments[segments.indexOf('tag') + 1];
      }
      return segments.isNotEmpty ? segments.last : null;
    } catch (e) {
      print("[GithubService] Error in tag redirect fallback: $e");
      return null;
    }
  }

  String? _buildAssetUrl(String tag, String suffix) {
    // We can't easily "search" assets without API, so we guess common names or constructs
    // However, GitHub direct download URLs follow a pattern:
    // https://github.com/owner/repo/releases/download/tag/filename
    
    // For Manfredonia, the .zip is usually named with version or just "Manfredonia-Pack.zip"
    // Since we don't know the exact name, this is a bit of a gamble without the API.
    // But we know the repo structure sometimes.
    
    // As a better fallback, we can point to the tag's release page download
    return 'https://github.com/$owner/$repo/releases/download/$tag/modpack$suffix';
    // Note: This relies on the file being named consistently. 
    // If it's not, the download will fail later but at least the UI won't be stuck.
  }
}

