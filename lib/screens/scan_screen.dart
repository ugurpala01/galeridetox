import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:photo_manager/photo_manager.dart';

import '../models/scan_result.dart';
import '../providers/keyword_provider.dart';
import '../services/battery_optimization_service.dart';
import '../services/keyword_matcher.dart';
import '../services/notification_service.dart';
import '../services/ocr_service.dart';
import '../services/photo_service.dart';
import '../services/onboarding_service.dart';
import '../services/permission_service.dart';
import '../services/scan_result_service.dart';
import '../services/statistics_service.dart';
import '../widgets/onboarding_tooltip.dart';
import 'history_screen.dart';
import 'permission_screen.dart';
import 'result_screen.dart';
import 'settings_screen.dart';

final scanProgressProvider = StateProvider<double>((ref) => 0.0);
final scanStatusProvider = StateProvider<String>((ref) => '');
final isScanningProvider = StateProvider<bool>((ref) => false);
final shouldCancelScanProvider = StateProvider<bool>((ref) => false);
final scanPhaseProvider = StateProvider<int>((ref) => 0);
final totalPhotosProvider = StateProvider<int>((ref) => 0);
final estimatedTimeProvider = StateProvider<String>((ref) => '');

class ScanScreen extends ConsumerStatefulWidget {
  const ScanScreen({super.key});

  @override
  ConsumerState<ScanScreen> createState() => _ScanScreenState();
}

class _ScanScreenState extends ConsumerState<ScanScreen> with WidgetsBindingObserver {
  final PhotoService _photoService = PhotoService();
  final OcrService _ocrService = OcrService();
  ScanResult? _latestResult;
  int? _newPhotoCount;
  bool _isCalculatingNewPhotos = false;

  // Arka plan durumu
  bool _isPaused = false;
  AppLifecycleState _appState = AppLifecycleState.resumed;

  // Tarama duraklatıldığında kaydetmek için
  List<dynamic>? _pendingDetectedAssets;
  int? _pendingTotalScanned;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _checkPhotoPermission();
    _loadLatestResult();
    _checkOnboarding();
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _ocrService.dispose();
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    _appState = state;
    if (state == AppLifecycleState.paused || state == AppLifecycleState.inactive) {
      _isPaused = true;
    } else if (state == AppLifecycleState.resumed) {
      _isPaused = false;
      _loadLatestResult();
      // Eğer tarama bitmiş ve sonuç bekliyorsa sonuç ekranını aç
      if (_pendingDetectedAssets != null && mounted) {
        final latestResult = ScanResultService.getLatestResult();
        Navigator.of(context).push(
          MaterialPageRoute(
            builder: (_) => ResultScreen(
              detectedAssets: _pendingDetectedAssets!,
              previousResult: latestResult,
              totalScanned: _pendingTotalScanned!,
            ),
          ),
        );
        _pendingDetectedAssets = null;
        _pendingTotalScanned = null;
      }
    }
  }

  Future<void> _checkPhotoPermission() async {
    final hasPermission = await PermissionService.requestPhotoPermissions();
    if (!hasPermission && mounted) {
      Navigator.of(context).pushReplacement(
        MaterialPageRoute(builder: (_) => const PermissionScreen()),
      );
    }
  }

  Future<void> _loadLatestResult() async {
    try {
      final result = await ScanResultService.getLatestResult();
      if (mounted) {
        setState(() {
          _latestResult = result;
        });
        _calculateNewPhotos();
      }
    } catch (e) {
      print('Sonuç yüklenirken hata: $e');
    }
  }

  Future<void> _calculateNewPhotos() async {
    if (_latestResult == null || _isCalculatingNewPhotos) return;

    setState(() {
      _isCalculatingNewPhotos = true;
    });

    try {
      final assets = await _photoService.loadAllImages();
      final lastScanDate = _latestResult!.scanDate;

      int newCount = 0;
      for (final asset in assets) {
        DateTime? createDate;
        if (asset is AssetEntity) {
          createDate = asset.createDateTime;
        } else if (asset is File) {
          try {
            createDate = asset.statSync().modified;
          } catch (e) {
            continue;
          }
        }

        if (createDate != null && createDate.isAfter(lastScanDate)) {
          newCount++;
        }
      }

      if (mounted) {
        setState(() {
          _newPhotoCount = newCount;
          _isCalculatingNewPhotos = false;
        });
      }
    } catch (e) {
      if (mounted) {
        setState(() {
          _isCalculatingNewPhotos = false;
        });
      }
    }
  }

  Future<void> _checkOnboarding() async {
    final shouldShow = !(await OnboardingService.isOnboardingCompleted());
    if (shouldShow && mounted) {
      await Future.delayed(const Duration(milliseconds: 500));
      _showOnboarding();
    }
  }

  void _showOnboarding() {
    showDialog(
      context: context,
      barrierDismissible: false,
      builder: (context) => OnboardingTooltip(
        title: 'Hoş Geldiniz!',
        description: 'Galeri Detoks ile WhatsApp ve galerideki kutlama mesajı görsellerini bulup temizleyebilirsiniz.',
        buttonText: 'Başla',
        onNext: () {
          OnboardingService.completeOnboarding();
          Navigator.pop(context);
        },
        isLastStep: true,
      ),
    );
  }

  Future<void> _showBatteryOptimizationDialog() async {
    final result = await showDialog<bool>(
      context: context,
      barrierDismissible: false,
      builder: (ctx) => AlertDialog(
        title: const Row(
          children: [
            Icon(Icons.battery_alert, color: Colors.orange),
            SizedBox(width: 8),
            Text('Pil Optimizasyonu'),
          ],
        ),
        content: const Text(
          'Telefon kilitliyken tarama durabilir. Daha güvenilir tarama için pil optimizasyonunu devre dışı bırakmanız önerilir.\n\n'
          'Gelen sistem dialogunda "İzin Ver" veya "Evet" seçeneğini tıklayın.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('Atla'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('İzin Ver'),
          ),
        ],
      ),
    );

    if (result == true) {
      final granted = await BatteryOptimizationService.requestIgnoreBatteryOptimizations();

      if (!granted && mounted) {
        final manualResult = await showDialog<bool>(
          context: context,
          builder: (ctx) => AlertDialog(
            title: const Text('Manuel Ayar Gerekli'),
            content: const Text(
              'Pil optimizasyonunu manuel olarak devre dışı bırakmanız gerekiyor.\n\n'
              'Ayarlar > Uygulamalar > Galeri Detoks > Pil > Kısıtlama Yok / Optimizasyonu Devre Dışı Bırak',
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(ctx, false),
                child: const Text('Kapat'),
              ),
              FilledButton(
                onPressed: () => Navigator.pop(ctx, true),
                child: const Text('Ayarları Aç'),
              ),
            ],
          ),
        );

        if (manualResult == true) {
          await BatteryOptimizationService.openAppSettingsPage();
        }
      }
    }
  }

  Future<void> _startScan({bool incremental = false}) async {
    print('>>> _startScan ÇAĞRILDI! incremental: $incremental');

    final hasPermission = await PermissionService.requestPhotoPermissions();
    if (!hasPermission) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('Fotoğraf erişim izni gerekli. Lütfen izin verin.'),
            backgroundColor: Colors.red,
            duration: Duration(seconds: 3),
          ),
        );
      }
      return;
    }

    final isBatteryOptDisabled = await BatteryOptimizationService.isBatteryOptimizationDisabled();
    if (!isBatteryOptDisabled && mounted) {
      await _showBatteryOptimizationDialog();
    }

    ref.read(shouldCancelScanProvider.notifier).state = false;
    ref.read(isScanningProvider.notifier).state = true;
    ref.read(scanPhaseProvider.notifier).state = 1;
    ref.read(scanProgressProvider.notifier).state = 0.0;
    ref.read(scanStatusProvider.notifier).state = 'Fotoğraflar aranıyor...';

    DateTime? lastScanDate;
    if (incremental && _latestResult != null) {
      lastScanDate = _latestResult!.scanDate;
    }

    try {
      final assets = await _photoService.loadAllImages();

      List<dynamic> photosToScan = assets;
      if (incremental && lastScanDate != null) {
        photosToScan = assets.where((asset) {
          DateTime? createDate;
          if (asset is AssetEntity) {
            createDate = asset.createDateTime;
          } else if (asset is File) {
            try {
              createDate = asset.statSync().modified;
            } catch (e) {
              return false;
            }
          }
          return createDate != null && createDate.isAfter(lastScanDate!);
        }).toList();
      }

      final total = photosToScan.length;

      if (ref.read(shouldCancelScanProvider)) {
        ref.read(scanStatusProvider.notifier).state = 'Tarama iptal edildi.';
        ref.read(isScanningProvider.notifier).state = false;
        return;
      }

      ref.read(totalPhotosProvider.notifier).state = total;
      ref.read(scanPhaseProvider.notifier).state = 2;

      if (total == 0) {
        ref.read(scanStatusProvider.notifier).state = 'Görsel bulunamadı.';
        ref.read(isScanningProvider.notifier).state = false;
        return;
      }

      // Mesajı biraz göster
      await Future.delayed(const Duration(milliseconds: 1500));

      final estimatedMinutes = (total * 200 / 60000).ceil();
      ref.read(estimatedTimeProvider.notifier).state =
          'Ortalama $estimatedMinutes dk sürecek';
      
      if (estimatedMinutes >= 10) {
        ref.read(scanStatusProvider.notifier).state = 
            'Tarama uzun sürebilir. İsterseniz başka uygulamalara geçebilirsiniz, ben arka planda çalışırım.';
      } else {
        ref.read(scanStatusProvider.notifier).state = 
            '$total fotoğraf bulundu, taramaya başlanıyor...';
      }

      // Uzun mesajı biraz göster
      await Future.delayed(const Duration(milliseconds: 2000));

      final selectedKeywords = ref.read(selectedKeywordsProvider);
      final List<dynamic> detected = [];
      final List<String> detectedAssetIds = [];

      // Bildirimi başlat
      await NotificationService.showProgressNotification(0, 0, total);

      final stopwatch = Stopwatch()..start();

      for (int i = 0; i < total; i++) {
        // Arka plan duraklatma kontrolü
        while (_isPaused && !_shouldCancel()) {
          await Future.delayed(const Duration(milliseconds: 500));
        }

        if (_shouldCancel()) {
          ref.read(scanStatusProvider.notifier).state = 'Tarama iptal edildi.';
          ref.read(isScanningProvider.notifier).state = false;
          await NotificationService.cancelAll();
          return;
        }

        try {
          final asset = photosToScan[i];
          String? filePath;
          String? assetId;

          if (asset is AssetEntity) {
            final file = await asset.file;
            filePath = file?.path;
            assetId = asset.id;
          } else if (asset is File) {
            filePath = asset.path;
            assetId = filePath;
          }

          if (filePath == null || assetId == null) continue;

          final text = await _ocrService.extractText(filePath);
          if (KeywordMatcher.hasKeyword(text, selectedKeywords)) {
            detected.add(asset);
            detectedAssetIds.add(assetId);
          }

          final progress = ((i + 1) / total * 100).toInt();
          ref.read(scanProgressProvider.notifier).state = (i + 1) / total;
          
          // 3 aşamalı bilgi mesajı (progress bazlı)
          String infoMessage;
          if (progress < 30) {
            infoMessage = 'Fotoğraflar taranıyor...';
          } else if (progress < 70) {
            infoMessage = 'Görsel analizi yapılıyor...';
          } else if (progress < 95) {
            infoMessage = 'Son kontroller yapılıyor...';
          } else {
            infoMessage = 'Neredeyse bitti...';
          }
          ref.read(scanStatusProvider.notifier).state = infoMessage;

          // Kalan süreyi gerçek veriye göre hesapla
          final elapsedMs = stopwatch.elapsedMilliseconds;
          final avgMsPerPhoto = elapsedMs / (i + 1);
          final remainingPhotos = total - (i + 1);
          final remainingMinutes = (remainingPhotos * avgMsPerPhoto / 60000).ceil();
          
          if (remainingMinutes > 0) {
            ref.read(estimatedTimeProvider.notifier).state =
                'Kalan süre: yaklaşık $remainingMinutes dk';
          } else {
            ref.read(estimatedTimeProvider.notifier).state =
                'Kalan süre: birkaç saniye';
          }

          // Her fotoğrafta bildirimi güncelle (1'er 1'er)
          await NotificationService.showProgressNotification(progress, i + 1, total);
        } catch (e) {
          continue;
        }
      }

      stopwatch.stop();

      if (_shouldCancel()) {
        ref.read(scanStatusProvider.notifier).state = 'Tarama iptal edildi.';
        ref.read(isScanningProvider.notifier).state = false;
        await NotificationService.cancelAll();
        return;
      }

      // Sonuçları kaydet
      final result = ScanResult(
        id: DateTime.now().millisecondsSinceEpoch.toString(),
        scanDate: DateTime.now(),
        detectedAssetIds: detectedAssetIds,
        totalScanned: total,
        detectedCount: detected.length,
        keywords: selectedKeywords,
      );
      await ScanResultService.saveResult(result);

      await StatisticsService.recordScan(
        totalScanned: total,
        detectedCount: detected.length,
        deletedCount: 0,
      );

      ref.read(isScanningProvider.notifier).state = false;
      ref.read(scanPhaseProvider.notifier).state = 0;
      ref.read(scanProgressProvider.notifier).state = 0.0;
      ref.read(scanStatusProvider.notifier).state = '';

      await NotificationService.showCompletionNotification(detected.length, total);

      if (mounted && _appState == AppLifecycleState.resumed) {
        // Uygulama öndeyse hemen sonuç ekranını aç
        await Navigator.of(context).push(
          MaterialPageRoute(
            builder: (_) => ResultScreen(
              detectedAssets: detected,
              previousResult: result,
              totalScanned: total,
            ),
          ),
        );
        _loadLatestResult();
      } else {
        // Uygulama arka plandaysa sonucu bekle
        _pendingDetectedAssets = detected;
        _pendingTotalScanned = total;
      }
    } catch (e) {
      ref.read(scanStatusProvider.notifier).state = 'Hata: $e';
      ref.read(isScanningProvider.notifier).state = false;
      ref.read(scanPhaseProvider.notifier).state = 0;
      await NotificationService.cancelAll();
    }
  }

  bool _shouldCancel() => ref.read(shouldCancelScanProvider);

  @override
  Widget build(BuildContext context) {
    final isScanning = ref.watch(isScanningProvider);
    final scanProgress = ref.watch(scanProgressProvider);
    final scanStatus = ref.watch(scanStatusProvider);
    final estimatedTime = ref.watch(estimatedTimeProvider);

    return Scaffold(
      appBar: AppBar(
        title: const Text('Galeri Detoks'),
        actions: [
          if (!isScanning)
            IconButton(
              icon: const Icon(Icons.history_rounded),
              tooltip: 'Geçmiş',
              onPressed: () {
                Navigator.of(context).push(
                  MaterialPageRoute(builder: (_) => const HistoryScreen()),
                );
              },
            ),
          if (!isScanning)
            IconButton(
              icon: const Icon(Icons.tune_rounded),
              tooltip: 'Tarama Ayarları',
              onPressed: () {
                Navigator.of(context).push(
                  MaterialPageRoute(builder: (_) => const SettingsScreen()),
                );
              },
            ),
          IconButton(
            icon: const Icon(Icons.logout_rounded),
            tooltip: 'Çıkış',
            onPressed: () async {
              if (ref.read(isScanningProvider)) {
                final shouldExit = await showDialog<bool>(
                  context: context,
                  builder: (ctx) => AlertDialog(
                    title: const Text('Tarama Devam Ediyor'),
                    content: const Text(
                      'Tarama sonlanacak ve çıkış yapılacak. Emin misiniz?',
                    ),
                    actions: [
                      TextButton(
                        onPressed: () => Navigator.pop(ctx, false),
                        child: const Text('İptal'),
                      ),
                      FilledButton(
                        onPressed: () => Navigator.pop(ctx, true),
                        child: const Text('Çıkış'),
                      ),
                    ],
                  ),
                );
                if (shouldExit != true) return;
                ref.read(shouldCancelScanProvider.notifier).state = true;
              }
              SystemNavigator.pop();
            },
          ),
        ],
      ),
      body: SafeArea(
        child: Padding(
          padding: const EdgeInsets.all(24.0),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              if (_latestResult != null && !isScanning) ...[
                _buildLastScanCard(),
                const SizedBox(height: 16),
              ],
              Expanded(
                child: Column(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    if (isScanning) ...[
                      // Mercek ikonu
                      Container(
                        width: 140,
                        height: 140,
                        decoration: BoxDecoration(
                          color: Theme.of(context).colorScheme.primaryContainer.withOpacity(0.3),
                          shape: BoxShape.circle,
                        ),
                        child: Center(
                          child: Icon(
                            Icons.search_rounded,
                            size: 56,
                            color: Theme.of(context).colorScheme.primary,
                          ),
                        ),
                      ),
                      const SizedBox(height: 16),
                      // Durum mesajı mercek altında
                      Container(
                        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
                        decoration: BoxDecoration(
                          color: Theme.of(context).colorScheme.surface.withOpacity(0.95),
                          borderRadius: BorderRadius.circular(20),
                          boxShadow: [
                            BoxShadow(
                              color: Colors.black.withOpacity(0.08),
                              blurRadius: 8,
                              offset: const Offset(0, 2),
                            ),
                          ],
                        ),
                        child: Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            Icon(
                              Icons.info_outline_rounded,
                              size: 18,
                              color: Theme.of(context).colorScheme.primary,
                            ),
                            const SizedBox(width: 8),
                            Flexible(
                              child: Text(
                                scanStatus,
                                style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                                      color: Theme.of(context).colorScheme.onSurface,
                                      fontWeight: FontWeight.w600,
                                    ),
                                textAlign: TextAlign.center,
                              ),
                            ),
                          ],
                        ),
                      ),
                      const SizedBox(height: 32),
                      Text(
                        'Taranıyor...',
                        style: Theme.of(context).textTheme.headlineMedium?.copyWith(
                          fontWeight: FontWeight.bold,
                        ),
                      ),
                      const SizedBox(height: 24),
                      LinearProgressIndicator(
                        value: scanProgress,
                        minHeight: 12,
                        borderRadius: BorderRadius.circular(6),
                      ),
                      const SizedBox(height: 12),
                      Text(
                        '${(scanProgress * 100).toInt()}%',
                        style: Theme.of(context).textTheme.titleLarge?.copyWith(
                          fontWeight: FontWeight.bold,
                          color: Theme.of(context).colorScheme.primary,
                        ),
                      ),
                      if (estimatedTime.isNotEmpty) ...[
                        const SizedBox(height: 16),
                        Container(
                          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
                          decoration: BoxDecoration(
                            color: Theme.of(context).colorScheme.primaryContainer.withOpacity(0.3),
                            borderRadius: BorderRadius.circular(12),
                          ),
                          child: Row(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              Icon(
                                Icons.access_time_rounded,
                                size: 18,
                                color: Theme.of(context).colorScheme.primary,
                              ),
                              const SizedBox(width: 8),
                              Flexible(
                                child: Text(
                                  estimatedTime,
                                  style: Theme.of(context).textTheme.bodyMedium,
                                  textAlign: TextAlign.center,
                                ),
                              ),
                            ],
                          ),
                        ),
                      ],
                    ] else ...[
                      Icon(
                        Icons.photo_library_outlined,
                        size: 80,
                        color: Theme.of(context).colorScheme.primary.withOpacity(0.5),
                      ),
                      const SizedBox(height: 24),
                      Text(
                        'Galerinizi Tarayın',
                        style: Theme.of(context).textTheme.headlineMedium?.copyWith(
                          fontWeight: FontWeight.bold,
                        ),
                      ),
                      const SizedBox(height: 12),
                      Text(
                        'WhatsApp ve galerideki kutlama mesajı görsellerini bulup temizleyin.',
                        style: Theme.of(context).textTheme.bodyLarge,
                        textAlign: TextAlign.center,
                      ),
                    ],
                  ],
                ),
              ),
              if (isScanning) ...[
                SizedBox(
                  width: double.infinity,
                  height: 56,
                  child: OutlinedButton.icon(
                    onPressed: () {
                      ref.read(shouldCancelScanProvider.notifier).state = true;
                      ref.read(isScanningProvider.notifier).state = false;
                      ref.read(scanStatusProvider.notifier).state = 'İptal ediliyor...';
                      NotificationService.cancelAll();
                    },
                    icon: const Icon(Icons.stop_rounded),
                    label: const Text('İptal Et', style: TextStyle(fontSize: 16)),
                  ),
                ),
              ] else ...[
                SizedBox(
                  width: double.infinity,
                  height: 56,
                  child: FilledButton.icon(
                    onPressed: () => _startScan(),
                    icon: const Icon(Icons.search_rounded),
                    label: const Text('Taramayı Başlat', style: TextStyle(fontSize: 16)),
                  ),
                ),
                if (_latestResult != null && _newPhotoCount != null && _newPhotoCount! > 0) ...[
                  const SizedBox(height: 12),
                  SizedBox(
                    width: double.infinity,
                    height: 56,
                    child: OutlinedButton.icon(
                      onPressed: () => _startScan(incremental: true),
                      icon: const Icon(Icons.update_rounded),
                      label: Text(
                        'Yeni Fotoğrafları Tara ($_newPhotoCount yeni)',
                        style: const TextStyle(fontSize: 16),
                      ),
                    ),
                  ),
                ],
              ],
              const SizedBox(height: 16),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildLastScanCard() {
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16.0),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Icon(Icons.history_rounded, color: Theme.of(context).colorScheme.primary),
                const SizedBox(width: 8),
                Text(
                  'Son Tarama',
                  style: Theme.of(context).textTheme.titleMedium?.copyWith(
                    fontWeight: FontWeight.bold,
                  ),
                ),
              ],
            ),
            const SizedBox(height: 8),
            Text(
              'Tarih: ${_latestResult!.scanDate.day}/${_latestResult!.scanDate.month}/${_latestResult!.scanDate.year}',
              style: Theme.of(context).textTheme.bodyMedium,
            ),
            Text(
              'Toplam: ${_latestResult!.totalScanned} fotoğraf',
              style: Theme.of(context).textTheme.bodyMedium,
            ),
            Text(
              'Bulunan: ${_latestResult!.detectedCount} kutlama görseli',
              style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                color: Theme.of(context).colorScheme.primary,
                fontWeight: FontWeight.bold,
              ),
            ),
          ],
        ),
      ),
    );
  }
}
