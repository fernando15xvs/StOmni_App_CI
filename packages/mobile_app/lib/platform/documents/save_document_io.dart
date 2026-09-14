import 'dart:io';
import 'package:core_logic/documents/domain/generated_document.dart';
import 'package:file_picker/file_picker.dart';

Future<DocumentOutputResult> saveDocument(GeneratedDocument document) async {
  final path = await FilePicker.platform.saveFile(
    dialogTitle: 'Guardar documento',
    fileName: document.fileName,
    type: FileType.custom,
    allowedExtensions: [document.kind.name],
  );
  if (path == null) return DocumentOutputResult.cancelled;
  await File(path).writeAsBytes(document.bytes);
  return DocumentOutputResult.saved;
}
