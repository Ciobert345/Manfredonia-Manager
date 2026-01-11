import 'dart:convert';
import 'dart:io';

import 'package:http/http.dart' as http;
import 'package:package_info_plus/package_info_plus.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

import 'update_service.dart';
import 'settings_service.dart';

class ManagerGithubRelease {
  final String tag;
  final String body;
  final String downloadUrl;

  ManagerGithubRelease({
    required this.tag,
    required this.body,
    required this.downloadUrl,
  });

  factory ManagerGithubRelease.fromJson(Map<String, dynamic> json) {
    final tag = (json['tag_name'] ?? '').toString();
    final body = (json['body'] ?? '').toString();

    String downloadUrl = '';
    final assets = json['assets'];
    if (assets is List) {
      // Prefer an installer asset if present (Inno Setup), otherwise fall back to any .exe.
      for (final asset in assets) {
        if (asset is! Map) continue;
        final name = (asset['name'] ?? '').toString().toLowerCase();
        final url = (asset['browser_download_url'] ?? '').toString();
        if (url.isEmpty) continue;

        if (name.endsWith('.exe') && (name.contains('setup') || name.contains('installer'))) {
          downloadUrl = url;
          break;
        }
      }
    }

    return ManagerGithubRelease(
      tag: tag,
      body: body,
      downloadUrl: downloadUrl,
    );
  }
}

class ManagerUpdateService {
  static const String _owner = 'Ciobert345';
  static const String _repo = 'Manfredonia-Manager';
  static const String _expectedInstallerAssetName = 'Manfredonia.Manager.Setup.exe';
  static const List<String> _installerAssetCandidates = [
    _expectedInstallerAssetName,
    'Manfredonia.Manager.Installer.exe',
    'ManfredoniaManagerSetup.exe',
    'ManfredoniaManagerInstaller.exe',
    'Manfredonia Manager setup.exe',
    'Manfredonia Manager Installer.exe',
  ];

  final UpdateService _updateService = UpdateService();

  Future<File> _getLogFile() async {
    final dir = await getTemporaryDirectory();
    return File(p.join(dir.path, 'manfredonia_manager_update.log'));
  }

  Future<void> _log(String message) async {
    try {
      final file = await _getLogFile();
      final line = '${DateTime.now().toIso8601String()}  $message\n';
      await file.writeAsString(line, mode: FileMode.append, flush: true);
    } catch (_) {
      // Ignore logging errors
    }
  }

  ManagerGithubRelease? _cachedRelease;
  DateTime? _lastFetch;
  final Duration _cacheTtl = const Duration(hours: 1); // Increased TTL to 1 hour

  Future<String?> _getLatestTagFromRedirect() async {
    final client = http.Client();
    final url = Uri.parse('https://github.com/$_owner/$_repo/releases/latest');

    try {
      await _log('Fallback redirect check: $url');

      final request = http.Request('GET', url);
      request.followRedirects = false;
      request.headers['User-Agent'] = 'ManfredoniaManager-Flutter';

      final response = await client.send(request).timeout(const Duration(seconds: 10));
      final location = response.headers['location'];
      await _log('Fallback redirect status=${response.statusCode} location=$location');

      if (location == null || location.isEmpty) return null;

      final locUri = Uri.parse(location);
      final segments = locUri.pathSegments;
      final tagIndex = segments.indexOf('tag');
      if (tagIndex >= 0 && tagIndex + 1 < segments.length) {
        final tag = segments[tagIndex + 1];
        if (tag.isNotEmpty) {
          await _log('Fallback extracted tag=$tag');
          return tag;
        }
      }

      final tag = segments.isNotEmpty ? segments.last : null;
      if (tag != null && tag.isNotEmpty) {
        await _log('Fallback extracted tag(last segment)=$tag');
        return tag;
      }

      return null;
    } catch (e) {
      await _log('Exception in _getLatestTagFromRedirect: $e');
      return null;
    } finally {
      client.close();
    }
  }

  String _buildInstallerDownloadUrl(String tag) {
    final tagEnc = Uri.encodeComponent(tag);
    final assetEnc = Uri.encodeComponent(_expectedInstallerAssetName);
    return 'https://github.com/$_owner/$_repo/releases/download/$tagEnc/$assetEnc';
  }

  String _buildDownloadUrlForTagAndAsset(String tag, String assetName) {
    final tagEnc = Uri.encodeComponent(tag);
    final assetEnc = Uri.encodeComponent(assetName);
    return 'https://github.com/$_owner/$_repo/releases/download/$tagEnc/$assetEnc';
  }

  Future<bool> _urlSeemsToExist(String url) async {
    final client = http.Client();
    try {
      final request = http.Request('HEAD', Uri.parse(url));
      request.followRedirects = false;
      request.headers['User-Agent'] = 'ManfredoniaManager-Flutter';
      final response = await client.send(request).timeout(const Duration(seconds: 10));

      // GitHub release assets usually respond 302 to a storage URL.
      if (response.statusCode == 200) return true;
      if (response.statusCode == 302 || response.statusCode == 301) return true;
      return false;
    } catch (_) {
      return false;
    } finally {
      client.close();
    }
  }

  Future<String?> _findInstallerUrlForTag(String tag) async {
    for (final asset in _installerAssetCandidates) {
      final url = _buildDownloadUrlForTagAndAsset(tag, asset);
      final ok = await _urlSeemsToExist(url);
      await _log('Fallback candidate check: asset=$asset ok=$ok url=$url');
      if (ok) return url;
    }

    return null;
  }

  Future<void> _validateWindowsExeFile(String path) async {
    final file = File(path);
    if (!await file.exists()) {
      throw Exception('Download non trovato su disco: $path');
    }

    final raf = await file.open();
    try {
      final header = await raf.read(2);
      final isMz = header.length == 2 && header[0] == 0x4D && header[1] == 0x5A;
      await _log('Downloaded file header=${header.map((b) => b.toRadixString(16).padLeft(2, "0")).join()} isMz=$isMz size=${await file.length()} path=$path');
      if (!isMz) {
        throw Exception(
          'Il file scaricato non è un eseguibile valido. Probabile nome asset errato o 404 HTML. ' 
          'Controlla che la Release GitHub contenga un installer Inno Setup (.exe) con nome tra: ${_installerAssetCandidates.join(", ")}',
        );
      }
    } finally {
      await raf.close();
    }
  }

  Future<ManagerGithubRelease?> getLatestRelease() async {
    await _log('getLatestRelease() called.');
    final settings = SettingsService();

    // 1. Check in-memory cache
    if (_cachedRelease != null && _lastFetch != null) {
      if (DateTime.now().difference(_lastFetch!) < _cacheTtl) {
        await _log('Returning in-memory cached release: tag=${_cachedRelease!.tag}');
        return _cachedRelease;
      }
    }

    // 2. Check persistent cache from SettingsService
    if (settings.managerReleaseCache != null && settings.managerLastFetch != null) {
      if (DateTime.now().difference(settings.managerLastFetch!) < _cacheTtl) {
        await _log('Returning persistent cached release: tag=${settings.managerReleaseCache?['tag_name']}');
        _cachedRelease = ManagerGithubRelease.fromJson(settings.managerReleaseCache!);
        _lastFetch = settings.managerLastFetch;
        return _cachedRelease;
      }
    }


    final url = Uri.parse('https://api.github.com/repos/$_owner/$_repo/releases/latest');

    try {
      final headers = {
        'User-Agent': 'ManfredoniaManager-Flutter',
        'Accept': 'application/vnd.github.v3+json',
      };

      if (settings.managerETag != null) {
        headers['If-None-Match'] = settings.managerETag!;
      }

      await _log('Fetching latest release from $url (ETag: ${settings.managerETag})');
      final response = await http.get(
        url,
        headers: headers,
      ).timeout(const Duration(seconds: 10));

      await _log('GitHub API status=${response.statusCode} length=${response.body.length}');

      if (response.statusCode == 200) {
        final parsed = json.decode(response.body);
        if (parsed is Map<String, dynamic>) {
          _cachedRelease = ManagerGithubRelease.fromJson(parsed);
          _lastFetch = DateTime.now();
          
          // Update persistent cache
          settings.managerReleaseCache = parsed;
          settings.managerLastFetch = _lastFetch;

          // Update ETag
          final etag = response.headers['etag'];
          if (etag != null) {
            settings.managerETag = etag;
          }

          await settings.saveSettings();
          
          await _log('Parsed release: tag=${_cachedRelease!.tag} downloadUrlEmpty=${_cachedRelease!.downloadUrl.isEmpty}');
        }
      } else if (response.statusCode == 304) {
        await _log('304 Not Modified. Returning cached release.');
        _lastFetch = DateTime.now();
        settings.managerLastFetch = _lastFetch;
        await settings.saveSettings();
        return _cachedRelease;
      } else if (response.statusCode == 403) {
        await _log('GitHub API rate limited, trying redirect fallback');
        final tag = await _getLatestTagFromRedirect();
        if (tag != null && tag.isNotEmpty) {
          final installerUrl = await _findInstallerUrlForTag(tag);
          
          final fallbackData = {
            'tag_name': tag,
            'body': '',
            'assets': [
              {
                'name': p.basename(installerUrl ?? _expectedInstallerAssetName),
                'browser_download_url': installerUrl ?? '',
              }
            ]
          };

          _cachedRelease = ManagerGithubRelease.fromJson(fallbackData);
          _lastFetch = DateTime.now();

          // Update persistent cache with fallback data
          settings.managerReleaseCache = fallbackData;
          settings.managerLastFetch = _lastFetch;
          await settings.saveSettings();

          await _log('Fallback release created and cached: tag=$tag url=${_cachedRelease!.downloadUrl}');
        } else {
          // If fallback fails, try using expired persistent cache as last resort
          if (settings.managerReleaseCache != null) {
            await _log('Fallback failed, using expired persistent cache as last resort');
            _cachedRelease = ManagerGithubRelease.fromJson(settings.managerReleaseCache!);
            return _cachedRelease;
          }
        }
      }
 else {
        await _log('Non-200 response body (first 400 chars): ${response.body.substring(0, response.body.length < 400 ? response.body.length : 400)}');
      }

      return _cachedRelease;
    } catch (e) {
      await _log('Exception in getLatestRelease: $e');
      return _cachedRelease;
    }
  }

  String _normalizeVersion(String v) {
    final match = RegExp(r'(\d+\.\d+(?:\.\d+)?)').firstMatch(v);
    if (match != null) return match.group(0)!;
    return v.trim().toLowerCase().replaceFirst('v', '');
  }

  Future<ManagerGithubRelease?> checkForUpdate() async {
    final info = await PackageInfo.fromPlatform();
    final local = _normalizeVersion(info.version);

    await _log('Local version: raw=${info.version} normalized=$local');

    final latest = await getLatestRelease();
    if (latest == null) {
      await _log('Latest release is null (no cache).');
      return null;
    }

    if (latest.downloadUrl.isEmpty) {
      await _log('Latest release has no installer downloadUrl (missing setup/installer asset).');
      return null;
    }

    final remote = _normalizeVersion(latest.tag);
    await _log('Remote version: tag=${latest.tag} normalized=$remote');

    if (remote.isEmpty) {
      await _log('Remote version empty -> no update.');
      return null;
    }

    if (remote == local) {
      await _log('Remote equals local -> up to date.');
      return null;
    }

    await _log('Update available: local=$local remote=$remote');

    return latest;
  }

  String _psQuote(String value) {
    // PowerShell single-quote escaping
    return value.replaceAll("'", "''");
  }

  Future<void> downloadAndRunInstaller(
    ManagerGithubRelease release, {
    Function(double progress)? onProgress,
    bool silent = true,
  }) async {
    if (release.downloadUrl.isEmpty) {
      throw Exception('Nessun installer (.exe) trovato nella release GitHub.');
    }

    final tempDir = await getTemporaryDirectory();
    final downloadPath = p.join(tempDir.path, 'Manfredonia.Manager.Setup_${release.tag}.exe');

    await _updateService.downloadFile(
      release.downloadUrl,
      downloadPath,
      (progress) {
        onProgress?.call(progress);
      },
    );

    await _validateWindowsExeFile(downloadPath);

    final args = <String>[];
    if (silent) {
      // Use /SILENT instead of /VERYSILENT to show progress bar and errors if any.
      // Removed /SUPPRESSMSGBOXES so errors are visible.
      args.addAll(['/SILENT', '/NORESTART']);
    }

    await _log('Launching installer: $downloadPath silent=$silent');

    await Process.start(
      downloadPath,
      args,
      mode: ProcessStartMode.detached,
    );

    exit(0);
  }
}
