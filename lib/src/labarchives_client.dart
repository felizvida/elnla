import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';

import 'backup_models.dart';

enum LabArchivesReadOnlyOperation {
  notebookBackup('notebooks', 'notebook_backup', {'uid', 'nbid', 'json'}),
  userAccessInfo('users', 'user_access_info', {'login_or_email', 'password'});

  const LabArchivesReadOnlyOperation(
    this.apiClass,
    this.method,
    this.allowedParams,
  );

  final String apiClass;
  final String method;
  final Set<String> allowedParams;
}

class LabArchivesClient {
  LabArchivesClient({
    required this.accessId,
    required this.accessKey,
    this.uid,
    HttpClient? httpClient,
  }) : _httpClient = httpClient ?? HttpClient();

  final String accessId;
  final String accessKey;
  final String? uid;
  final HttpClient _httpClient;

  static const _mutableMethodPrefixes = [
    'add_',
    'assign_',
    'copy_',
    'create_',
    'delete_',
    'grant_',
    'insert_',
    'move_',
    'patch_',
    'post_',
    'put_',
    'remove_',
    'replace_',
    'restore_',
    'revoke_',
    'share_',
    'submit_',
    'update_',
    'upload_',
  ];

  static bool isReadOnlyElnOperation(String apiClass, String method) {
    final cleanClass = apiClass.trim();
    final cleanMethod = method.trim();
    if (_hasMutableMethodName(cleanMethod)) {
      return false;
    }
    return LabArchivesReadOnlyOperation.values.any(
      (operation) =>
          operation.apiClass == cleanClass && operation.method == cleanMethod,
    );
  }

  static void assertReadOnlyElnOperation({
    required String apiClass,
    required String method,
    Iterable<String> paramKeys = const [],
  }) {
    final cleanClass = apiClass.trim();
    final cleanMethod = method.trim();
    if (_hasMutableMethodName(cleanMethod)) {
      throw LabArchivesException(
        'Refusing mutable LabArchives endpoint $cleanClass::$cleanMethod.',
      );
    }
    LabArchivesReadOnlyOperation? operation;
    for (final candidate in LabArchivesReadOnlyOperation.values) {
      if (candidate.apiClass == cleanClass && candidate.method == cleanMethod) {
        operation = candidate;
        break;
      }
    }
    final matchedOperation = operation;
    if (matchedOperation == null) {
      throw LabArchivesException(
        'LabArchives endpoint $cleanClass::$cleanMethod is not allowlisted for BenchVault production use.',
      );
    }
    final unexpected =
        paramKeys
            .where((key) => !matchedOperation.allowedParams.contains(key))
            .toList()
          ..sort();
    if (unexpected.isNotEmpty) {
      throw LabArchivesException(
        'Unexpected parameters for $cleanClass::$cleanMethod: ${unexpected.join(', ')}.',
      );
    }
  }

  static bool _hasMutableMethodName(String method) {
    final clean = method.trim().toLowerCase();
    return _mutableMethodPrefixes.any(clean.startsWith);
  }

  Future<File> downloadNotebookBackup({
    required NotebookSummary notebook,
    required File destination,
  }) async {
    final userId = uid;
    if (userId == null || userId.isEmpty) {
      throw const LabArchivesException('Missing LabArchives UID.');
    }
    // Do not send no_attachments=true: the archive is the preservation copy and
    // must include full-size original attachment payloads.
    final uri = _readOnlyElnUri(
      operation: LabArchivesReadOnlyOperation.notebookBackup,
      params: {'uid': userId, 'nbid': notebook.nbid, 'json': 'true'},
    );
    final request = await _httpClient.getUrl(uri);
    request.headers.set(
      HttpHeaders.userAgentHeader,
      'benchvault-readonly-backup/0.1',
    );
    final response = await request.close();
    if (response.statusCode != HttpStatus.ok) {
      final body = await utf8.decodeStream(response);
      throw LabArchivesException(
        'Backup failed for ${notebook.name}: HTTP ${response.statusCode} ${_safeError(body)}',
      );
    }
    await destination.parent.create(recursive: true);
    final sink = destination.openWrite();
    await response.pipe(sink);
    return destination;
  }

  Future<String> fetchUserAccessInfoXml({
    required String email,
    required String authCode,
  }) async {
    final uri = _readOnlyElnUri(
      operation: LabArchivesReadOnlyOperation.userAccessInfo,
      params: {'login_or_email': email, 'password': authCode},
    );
    final request = await _httpClient.getUrl(uri);
    request.headers.set(
      HttpHeaders.userAgentHeader,
      'benchvault-readonly-setup/0.1',
    );
    final response = await request.close();
    final body = await utf8.decodeStream(response);
    if (response.statusCode != HttpStatus.ok) {
      throw LabArchivesException(
        'Authorization failed: HTTP ${response.statusCode} ${_safeError(body)}',
      );
    }
    return body;
  }

  Uri buildUserLoginUri({required String redirectUri}) {
    final expires = '${DateTime.now().millisecondsSinceEpoch}';
    final sig = _signatureFor(redirectUri, expires);
    return Uri.https('api.labarchives-gov.com', '/api_user_login', {
      'akid': accessId,
      'expires': expires,
      'redirect_uri': redirectUri,
      'sig': sig,
    });
  }

  Uri _readOnlyElnUri({
    required LabArchivesReadOnlyOperation operation,
    required Map<String, String> params,
  }) {
    assertReadOnlyElnOperation(
      apiClass: operation.apiClass,
      method: operation.method,
      paramKeys: params.keys,
    );
    final expires = '${DateTime.now().millisecondsSinceEpoch}';
    final sig = _signatureFor(operation.method, expires);
    return Uri.https(
      'api.labarchives-gov.com',
      '/api/${operation.apiClass}/${operation.method}',
      {...params, 'akid': accessId, 'expires': expires, 'sig': sig},
    );
  }

  String _signatureFor(String method, String expires) {
    final key = utf8.encode(accessKey);
    final message = utf8.encode('$accessId$method$expires');
    return base64Encode(Hmac(sha1, key).convert(message).bytes);
  }

  String _safeError(String body) {
    final code = RegExp(
      r'<error-code[^>]*>(.*?)</error-code>',
      dotAll: true,
    ).firstMatch(body)?.group(1);
    final description = RegExp(
      r'<error-description[^>]*>(.*?)</error-description>',
      dotAll: true,
    ).firstMatch(body)?.group(1);
    if (code != null || description != null) {
      final parts = <String>[];
      if (code != null) {
        parts.add('code $code');
      }
      if (description != null) {
        parts.add(description.trim());
      }
      return parts.join(': ');
    }
    return body.replaceAll(RegExp(r'\s+'), ' ').trim();
  }
}

class LabArchivesException implements Exception {
  const LabArchivesException(this.message);

  final String message;

  @override
  String toString() => message;
}
