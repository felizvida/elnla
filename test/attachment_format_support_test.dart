import 'package:elnla/src/attachment_format_support.dart';
import 'package:elnla/src/backup_models.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('classifies LabArchives-supported attachment families', () {
    expect(
      _support('gel.png', contentType: 'image/png').previewMode,
      AttachmentPreviewMode.inlineImage,
    );
    expect(
      _support('vector.svg', contentType: 'image/svg+xml').previewMode,
      AttachmentPreviewMode.inlineText,
    );
    expect(
      _support('raw_image.tif').previewMode,
      AttachmentPreviewMode.externalViewer,
    );
    expect(_support('protocol.docx').labArchivesDirectView, isTrue);
    expect(
      _support('analysis.ipynb').previewMode,
      AttachmentPreviewMode.jupyterSummary,
    );
    expect(_support('plasmid.dna').family, 'Molecular biology project file');
    expect(
      _support('sanger_trace.ab1').previewMode,
      AttachmentPreviewMode.externalViewer,
    );
    expect(
      _support('amplicon.fasta').previewMode,
      AttachmentPreviewMode.inlineText,
    );
    expect(
      _support('compound.sdf').previewMode,
      AttachmentPreviewMode.inlineText,
    );
    expect(
      _support('archive.zip').previewMode,
      AttachmentPreviewMode.downloadOnly,
    );
    expect(_support('instrument_export.custom').family, 'Generic attachment');
  });
}

AttachmentFormatSupport _support(String filename, {String? contentType}) {
  return attachmentFormatSupport(
    RenderPart(
      id: 1,
      kindCode: 2,
      kindLabel: 'Attachment',
      renderText: '',
      position: 1,
      attachmentName: filename,
      attachmentContentType: contentType,
    ),
  );
}
