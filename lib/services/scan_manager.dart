import 'dart:isolate';
import 'package:flutter_foreground_task/flutter_foreground_task.dart';
import 'package:photo_manager/photo_manager.dart';
import 'package:hive_flutter/hive_flutter.dart';
import 'keyword_matcher.dart';
import 'ocr_service.dart';
import 'photo_service.dart';
import '../models/scan_result.dart';
import 'scan_result_service.dart';

// Arka plan görevi için ayrılmış Handler
class ScanTaskHandler extends TaskHandler {
  @override
  Future<void> onStart(DateTime timestamp, SendPort? sendPort) async {
    // Servis başladığında yapılacak bir şey varsa buraya
  }

  @override
  Future<void> onRepeatEvent(DateTime timestamp, SendPort? sendPort) async {
    // Tekrarlayan görevler için
  }

  @override
  Future<void> onDestroy(DateTime timestamp, SendPort? sendPort) async {
    // Servis durduğunda temizlik
  }
}

class ScanManager {
  static final OcrService _ocrService = OcrService();
  static final PhotoService _photoService = PhotoService();

  static Future<void> startScan({
    required List<String> keywords,
    Function(int progress, int scanned, int total)? onProgress,
  }) async {
    final assets = await _photoService.loadAllImages();
    final List<String> detectedIds = [];
    var cacheBox = await Hive.openBox('ocr_cache');

    for (int i = 0; i < assets.length; i++) {
      final asset = assets[i];
      final id = asset.id;
      final path = await PhotoService.getPath(asset);

      if (path == null) continue;

      String text;
      if (cacheBox.containsKey(id)) {
        text = cacheBox.get(id);
      } else {
        text = await _ocrService.extractText(path);
        await cacheBox.put(id, text);
      }

      if (KeywordMatcher.analyze(text).isDetected) {
        detectedIds.add(id);
      }

      if (onProgress != null) {
        onProgress(((i + 1) / assets.length * 100).toInt(), i + 1, assets.length);
      }
    }

    final scanResult = ScanResult(
      id: DateTime.now().millisecondsSinceEpoch.toString(),
      scanDate: DateTime.now(),
      detectedAssetIds: detectedIds,
      totalScanned: assets.length,
      detectedCount: detectedIds.length,
      keywords: keywords,
    );
    await ScanResultService.saveResult(scanResult);
  }
}
