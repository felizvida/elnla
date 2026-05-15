import 'backup_models.dart';

enum AttachmentPreviewMode {
  inlineImage,
  inlineText,
  jupyterSummary,
  externalViewer,
  downloadOnly,
}

class AttachmentFormatSupport {
  const AttachmentFormatSupport({
    required this.family,
    required this.labArchivesSupport,
    required this.elnlaSupport,
    required this.previewMode,
    this.labArchivesDirectView = false,
  });

  final String family;
  final String labArchivesSupport;
  final String elnlaSupport;
  final AttachmentPreviewMode previewMode;
  final bool labArchivesDirectView;

  bool get hasInlinePreview =>
      previewMode == AttachmentPreviewMode.inlineImage ||
      previewMode == AttachmentPreviewMode.inlineText ||
      previewMode == AttachmentPreviewMode.jupyterSummary;
}

AttachmentFormatSupport attachmentFormatSupport(RenderPart part) {
  final extension = attachmentExtension(part.attachmentName);
  final contentType = (part.attachmentContentType ?? '').toLowerCase();

  if (_browserImageExtensions.contains(extension) ||
      contentType.startsWith('image/') &&
          extension != '.svg' &&
          extension != '.tif' &&
          extension != '.tiff') {
    return const AttachmentFormatSupport(
      family: 'Browser image',
      labArchivesSupport:
          'LabArchives can directly view common browser images and annotate JPG, PNG, and GIF images.',
      elnlaSupport:
          'ELNLA previews this image inline and restores the original file.',
      previewMode: AttachmentPreviewMode.inlineImage,
      labArchivesDirectView: true,
    );
  }
  if (extension == '.tif' || extension == '.tiff') {
    return const AttachmentFormatSupport(
      family: 'TIFF image',
      labArchivesSupport:
          'LabArchives stores TIFF files, but its Image Annotator notes that TIFF is not browser-native.',
      elnlaSupport:
          'ELNLA preserves and restores the original TIFF; open it in an image-analysis tool for viewing.',
      previewMode: AttachmentPreviewMode.externalViewer,
    );
  }
  if (extension == '.pdf' || contentType == 'application/pdf') {
    return const AttachmentFormatSupport(
      family: 'PDF document',
      labArchivesSupport: 'LabArchives can directly view PDF attachments.',
      elnlaSupport:
          'ELNLA recognizes the PDF, preserves the original, and restores it for local viewing.',
      previewMode: AttachmentPreviewMode.externalViewer,
      labArchivesDirectView: true,
    );
  }
  if (_officeExtensions.contains(extension)) {
    return const AttachmentFormatSupport(
      family: 'Microsoft Office document',
      labArchivesSupport:
          'LabArchives can view Word, Excel, and PowerPoint files through Office for the Web; newer formats can be edited when enabled.',
      elnlaSupport:
          'ELNLA recognizes Office files, preserves the original, and restores it for local Office-compatible viewing.',
      previewMode: AttachmentPreviewMode.externalViewer,
      labArchivesDirectView: true,
    );
  }
  if (extension == '.ipynb') {
    return const AttachmentFormatSupport(
      family: 'Jupyter notebook',
      labArchivesSupport:
          'LabArchives can view Jupyter notebooks in its Docs Viewer.',
      elnlaSupport:
          'ELNLA summarizes notebook cells inline and restores the original .ipynb file.',
      previewMode: AttachmentPreviewMode.jupyterSummary,
      labArchivesDirectView: true,
    );
  }
  if (_textPreviewExtensions.contains(extension) ||
      contentType.startsWith('text/') ||
      contentType.contains('json') ||
      contentType.contains('xml')) {
    return const AttachmentFormatSupport(
      family: 'Text or tabular file',
      labArchivesSupport:
          'LabArchives can directly view and index supported text files under the attachment size threshold.',
      elnlaSupport:
          'ELNLA previews the text inline and restores the original file.',
      previewMode: AttachmentPreviewMode.inlineText,
      labArchivesDirectView: true,
    );
  }
  if (_molecularTextExtensions.contains(extension)) {
    return const AttachmentFormatSupport(
      family: 'Molecular sequence text',
      labArchivesSupport:
          'LabArchives SnapGene/Geneious integrations support common sequence formats such as FASTA, GenBank, and EMBL.',
      elnlaSupport:
          'ELNLA previews text-based sequence content inline and restores the original file.',
      previewMode: AttachmentPreviewMode.inlineText,
      labArchivesDirectView: true,
    );
  }
  if (_snapGeneBinaryExtensions.contains(extension)) {
    return const AttachmentFormatSupport(
      family: 'Molecular biology project file',
      labArchivesSupport:
          'LabArchives SnapGene/Geneious integrations support this sequence-project family and may show a sequence preview.',
      elnlaSupport:
          'ELNLA recognizes the format and restores the original file for SnapGene, Geneious, or compatible tools.',
      previewMode: AttachmentPreviewMode.externalViewer,
      labArchivesDirectView: true,
    );
  }
  if (_chemicalExtensions.contains(extension)) {
    return AttachmentFormatSupport(
      family: 'Chemical structure file',
      labArchivesSupport:
          'LabArchives Inventory accepts chemical file formats including CDX, CDXML, MOL, SDF, and SKC.',
      elnlaSupport: _chemicalTextExtensions.contains(extension)
          ? 'ELNLA previews this text-based chemical file inline and restores the original file.'
          : 'ELNLA recognizes the format and restores the original file for a chemical drawing or structure tool.',
      previewMode: _chemicalTextExtensions.contains(extension)
          ? AttachmentPreviewMode.inlineText
          : AttachmentPreviewMode.externalViewer,
      labArchivesDirectView: true,
    );
  }
  if (_mediaExtensions.contains(extension) ||
      contentType.startsWith('audio/') ||
      contentType.startsWith('video/')) {
    return const AttachmentFormatSupport(
      family: 'Media file',
      labArchivesSupport:
          'LabArchives can store media attachments and commonly shows recognized media with viewer or file-type controls.',
      elnlaSupport:
          'ELNLA preserves and restores the original media file for local playback.',
      previewMode: AttachmentPreviewMode.externalViewer,
    );
  }
  if (_archiveExtensions.contains(extension)) {
    return const AttachmentFormatSupport(
      family: 'Archive or package',
      labArchivesSupport:
          'LabArchives stores arbitrary attachment formats, including packages and archives.',
      elnlaSupport:
          'ELNLA preserves and restores the original archive without unpacking it in the read-only viewer.',
      previewMode: AttachmentPreviewMode.downloadOnly,
    );
  }
  return const AttachmentFormatSupport(
    family: 'Generic attachment',
    labArchivesSupport:
        'LabArchives allows documents of any file type and format to be attached to a notebook page.',
    elnlaSupport:
        'ELNLA preserves the original payload and restores it even when no inline preview is available.',
    previewMode: AttachmentPreviewMode.downloadOnly,
  );
}

String attachmentExtension(String? filename) {
  final clean = filename?.trim().toLowerCase() ?? '';
  final index = clean.lastIndexOf('.');
  if (index <= 0 || index == clean.length - 1) {
    return '';
  }
  return clean.substring(index);
}

const _browserImageExtensions = {
  '.png',
  '.jpg',
  '.jpeg',
  '.gif',
  '.webp',
  '.bmp',
};

const _officeExtensions = {
  '.doc',
  '.docx',
  '.xls',
  '.xlsx',
  '.xlsm',
  '.xlsb',
  '.ppt',
  '.pptx',
  '.pps',
  '.ppsx',
};

const _textPreviewExtensions = {
  '.txt',
  '.csv',
  '.tsv',
  '.md',
  '.json',
  '.xml',
  '.yaml',
  '.yml',
  '.html',
  '.htm',
  '.log',
  '.ini',
  '.conf',
  '.rtf',
  '.svg',
  '.bed',
  '.vcf',
  '.gff',
  '.gff3',
  '.gtf',
};

const _molecularTextExtensions = {
  '.fa',
  '.fasta',
  '.fas',
  '.fq',
  '.fastq',
  '.gb',
  '.gbk',
  '.genbank',
  '.embl',
  '.seq',
};

const _snapGeneBinaryExtensions = {
  '.dna',
  '.xdna',
  '.clc',
  '.pdw',
  '.cx5',
  '.cm5',
  '.nucl',
  '.gcproj',
  '.cow',
  '.gcc',
  '.sbd',
  '.geneious',
  '.ab1',
};

const _chemicalExtensions = {'.cdx', '.cdxml', '.mol', '.sdf', '.skc'};

const _chemicalTextExtensions = {'.cdxml', '.mol', '.sdf'};

const _mediaExtensions = {
  '.mp3',
  '.wav',
  '.m4a',
  '.aac',
  '.mp4',
  '.mov',
  '.m4v',
  '.avi',
};

const _archiveExtensions = {
  '.zip',
  '.7z',
  '.tar',
  '.gz',
  '.tgz',
  '.bz2',
  '.xz',
};
