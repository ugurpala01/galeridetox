import 'package:google_mlkit_text_recognition/google_mlkit_text_recognition.dart';

/// Google ML Kit kullanarak görsellerdeki metni tanıyan OCR servisi.
class OcrService {
  final TextRecognizer _recognizer = TextRecognizer(
    script: TextRecognitionScript.latin,
  );

  /// Verilen görsel dosya yolundaki metni OCR ile çıkarır.
  /// Metin bulunamazsa boş string döner.
  Future<String> extractText(String imagePath) async {
    try {
      final inputImage = InputImage.fromFilePath(imagePath);
      final RecognizedText result = await _recognizer.processImage(inputImage);
      return result.text;
    } catch (e) {
      return '';
    }
  }

  /// Kaynakları serbest bırakır. Uygulama kapanırken çağırın.
  void dispose() {
    _recognizer.close();
  }
}
