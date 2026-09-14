import 'package:core_logic/platform/image_selection.dart';
import 'package:image_cropper/image_cropper.dart';
import 'package:image_picker/image_picker.dart';

class MobileImageSelectionAdapter implements ImageSelectionPort {
  MobileImageSelectionAdapter({ImagePicker? picker, ImageCropper? cropper})
    : _picker = picker ?? ImagePicker(),
      _cropper = cropper ?? ImageCropper();

  final ImagePicker _picker;
  final ImageCropper _cropper;

  @override
  Future<SelectedImageData?> select(ImageSelectionRequest request) async {
    final picked = await _picker.pickImage(
      source: switch (request.source) {
        ImageSelectionSource.camera => ImageSource.camera,
        ImageSelectionSource.gallery => ImageSource.gallery,
      },
      maxWidth: request.maxWidth,
      maxHeight: request.maxHeight,
      imageQuality: _boundedQuality(request.imageQuality),
      preferredCameraDevice: CameraDevice.rear,
    );
    if (picked == null) return null;

    if (request.crop) {
      final cropped = await _cropper.cropImage(
        sourcePath: picked.path,
        compressFormat: ImageCompressFormat.jpg,
        compressQuality: _boundedQuality(request.cropQuality),
        uiSettings: [
          AndroidUiSettings(
            toolbarTitle: 'Ajustar imagen',
            initAspectRatio: CropAspectRatioPreset.square,
            lockAspectRatio: false,
            aspectRatioPresets: const [
              CropAspectRatioPreset.square,
              CropAspectRatioPreset.ratio3x2,
              CropAspectRatioPreset.ratio4x3,
              CropAspectRatioPreset.original,
            ],
          ),
          IOSUiSettings(
            title: 'Ajustar imagen',
            aspectRatioPresets: const [
              CropAspectRatioPreset.square,
              CropAspectRatioPreset.ratio3x2,
              CropAspectRatioPreset.ratio4x3,
              CropAspectRatioPreset.original,
            ],
          ),
        ],
      );
      if (cropped == null) return null;
      return SelectedImageData(
        bytes: await cropped.readAsBytes(),
        extension: 'jpg',
        fileName: picked.name,
      );
    }

    return SelectedImageData(
      bytes: await picked.readAsBytes(),
      extension: _extensionOf(picked.name),
      fileName: picked.name,
    );
  }

  static int _boundedQuality(int value) {
    if (value < 0) return 0;
    if (value > 100) return 100;
    return value;
  }

  static String _extensionOf(String name) {
    final normalized = name.trim();
    final dot = normalized.lastIndexOf('.');
    if (dot < 0 || dot == normalized.length - 1) return 'png';
    final value = normalized.substring(dot + 1).toLowerCase();
    return switch (value) {
      'jpeg' => 'jpg',
      'jpg' || 'png' || 'webp' => value,
      _ => 'png',
    };
  }
}
