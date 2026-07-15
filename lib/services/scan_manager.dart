import 'dart:io';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:photo_manager/photo_manager.dart';
import 'package:hive_flutter/hive_flutter.dart';
import 'keyword_matcher.dart';
import 'ocr_service.dart';
import 'photo_service.dart';
import '../models/scan_result.dart';
import 'scan_result_service.dart';

class ScanManager {
  static final OcrService _ocrService = OcrService();
  static final PhotoService _photoService = PhotoService();

  /// Ana tarama fonksiyonu
  static Future<void> startScan({
    required List<String> keywords,
    Function(int progress, int scanned, int total)? onProgress,
    bool incremental = false,
  }) async {
    final assets = await _photoService.loadAllImages();
    final List<dynamic> detected = [];
    final List<String> detectedIds = [];
    
    // Hive üzerinden önbellek kontrolü (Yeni eklenen özellik)
    var cacheBox = await Hive.openBox('ocr_cache');

    for (int i = 0; i < assets.length; i++) {
      final asset = assets[i];
      final id = asset is AssetEntity ? asset.id : asset.path;
      final path = await PhotoService.getPath(asset);

      if (path == null) continue;

      String text;
      // Eğer daha önce taranmışsa OCR yapma, önbellekten oku
      if (cacheBox.containsKey(id)) {
        text = cacheBox.get(id);
      } else {
        text = await _ocrService.extractText(path);
        await cacheBox.put(id, text); // Önbelleğe al
      }

      final result = KeywordMatcher.analyze(text);
      if (result.isDetected) {
        detected.add(asset);
        detectedIds.add(id);
      }

      if (onProgress != null) {
        onProgress(((i + 1) / assets.length * 100).toInt(), i + 1, assets.length);
      }
    }

    // Sonucu kaydet
    final scanResult = ScanResult(
      id: DateTime.now().millisecondsSinceEpoch.toString(),
      scanDate: DateTime.now(),
      detectedAssetIds: detectedIds,
      totalScanned: assets.length,
      detectedCount: detected.length,
      keywords: keywords,
    );
    await ScanResultService.saveResult(scanResult);
  }
}
