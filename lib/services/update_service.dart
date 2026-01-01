import 'dart:convert';
import 'dart:io';
import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;
import 'package:archive/archive.dart';
import 'package:path/path.dart' as p;

// Top-level function for compute
Archive _decodeZip(List<int> bytes) {
  return ZipDecoder().decodeBytes(bytes);
}

class UpdateService {
  Future<void> updatePack(
    String instancePath,
    String downloadUrl,
    Function(double progress, String? status) onProgress, {
    List<String> preservedFiles = const [],
  }) async {
    final client = http.Client();
    final request = http.Request('GET', Uri.parse(downloadUrl));
    final response = await client.send(request);

    final totalSize = response.contentLength ?? 0;
    int downloadedSize = 0;
    final buffer = BytesBuilder(copy: false);

    await for (var chunk in response.stream) {
      buffer.add(chunk);
      downloadedSize += chunk.length;
      if (totalSize > 0) {
        onProgress((downloadedSize / totalSize) * 0.5, 'downloading'); 
      }
    }

    final bytes = buffer.takeBytes();

    // Decode in a separate isolate to avoid UI freeze
    onProgress(0.55, 'analyzing');
    final archive = await compute(_decodeZip, bytes);

    // Identify top-level folders in the archive
    final foldersInArchive = <String>{};
    for (var file in archive) {
      final name = file.name.replaceAll('\\', '/');
      final parts = name.split('/');
      if (parts.isNotEmpty) {
        final top = parts.first;
        if (parts.length > 1 || !file.isFile) {
           if (top.isNotEmpty) foldersInArchive.add(top);
        }
      }
    }

    // Cleanup folders
    onProgress(0.58, 'cleaning');
    
    for (var folder in foldersInArchive) {
      final dir = Directory(p.join(instancePath, folder));
      if (!await dir.exists()) continue;

      if (folder == 'mods') {
        // Selective cleanup for mods
        final entries = await dir.list().toList();
        for (var entry in entries) {
          if (entry is File) {
            final fileName = p.basename(entry.path);
            if (!preservedFiles.contains(fileName)) {
              await entry.delete();
            }
          } else if (entry is Directory) {
            await entry.delete(recursive: true);
          }
        }
      } else {
        // Full delete for other folders (REPLACE behavior)
        await dir.delete(recursive: true);
      }
    }

    // Extract
    onProgress(0.60, 'extracting');
    final totalFiles = archive.length;
    int extractedFiles = 0;

    for (var file in archive) {
      final filename = file.name;
      String? currentStatus;
      
      if (filename.startsWith('mods/')) {
        currentStatus = 'mods';
      } else if (filename.startsWith('config/') || filename.startsWith('defaultconfigs/')) {
        currentStatus = 'config';
      } else if (filename.startsWith('scripts/') || filename.startsWith('kubejs/')) {
        currentStatus = 'scripts';
      }

      if (file.isFile) {
        final data = file.content as List<int>;
        final outFile = File(p.join(instancePath, filename));
        await outFile.create(recursive: true);
        await outFile.writeAsBytes(data);
      } else {
        await Directory(p.join(instancePath, filename)).create(recursive: true);
      }
      
      extractedFiles++;
      onProgress(0.6 + (extractedFiles / totalFiles) * 0.4, currentStatus); 
    }

    onProgress(1.0, 'completed');
  }

  Future<void> downloadFile(
    String url,
    String savePath,
    Function(double progress) onProgress,
  ) async {
    final client = http.Client();
    final request = http.Request('GET', Uri.parse(url));
    final response = await client.send(request);

    final totalSize = response.contentLength ?? 0;
    int downloadedSize = 0;
    final file = File(savePath);
    final IOSink sink = file.openWrite();

    await for (var chunk in response.stream) {
      sink.add(chunk);
      downloadedSize += chunk.length;
      if (totalSize > 0) {
        onProgress(downloadedSize / totalSize);
      }
    }

    await sink.close();
    client.close();
  }
}
