import 'dart:io';
import 'dart:typed_data';
import 'package:google_mlkit_text_recognition/google_mlkit_text_recognition.dart';
import 'package:image/image.dart' as img;

class OcrService {
  static final OcrService _instance = OcrService._internal();
  factory OcrService() => _instance;
  OcrService._internal();

  final TextRecognizer _textRecognizer = TextRecognizer(script: TextRecognitionScript.latin);

  Future<String> extractText(String imagePath) async {
    try {
      final File imageFile = File(imagePath);
      
      // HIZLANDIRMA: Görseli optimize et (Küçültme)
      final Uint8List bytes = await imageFile.readAsBytes();
      img.Image? originalImage = img.decodeImage(bytes);
      
      if (originalImage == null) return '';

      // Genişliği 600px yap (Okunabilirlik için yeterli, hız için muazzam)
      img.Image resizedImage = img.copyResize(originalImage, width: 600);
      
      // Geçici dosyaya yaz (ML Kit dosya yolu beklediği için)
      final tempDir = Directory.systemTemp;
      final tempFile = File('${tempDir.path}/temp_ocr.jpg');
      await tempFile.writeAsBytes(img.encodeJpg(resizedImage, quality: 80));

      final inputImage = InputImage.fromFilePath(tempFile.path);
      final RecognizedText recognizedText = await _textRecognizer.processImage(inputImage);
      
      // Geçici dosyayı sil (Bellek temizliği)
      if (await tempFile.exists()) await tempFile.delete();

      return recognizedText.text;
    } catch (e) {
      print("OCR Hatası: $e");
      return '';
    }
  }

  void dispose() {
    _textRecognizer.close();
  }
}
