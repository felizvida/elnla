import 'dart:io';

import 'package:benchvault/src/labarchives_client.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('LabArchives production endpoints are explicitly read-only', () {
    expect(
      LabArchivesClient.isReadOnlyElnOperation('notebooks', 'notebook_backup'),
      isTrue,
    );
    expect(
      LabArchivesClient.isReadOnlyElnOperation('users', 'user_access_info'),
      isTrue,
    );

    for (final endpoint in const [
      ('entries', 'add_entry'),
      ('entries', 'add_attachment'),
      ('entries', 'add_comment'),
      ('tree_tools', 'insert_node'),
      ('notebooks', 'create_notebook'),
      ('entries', 'update_entry'),
      ('entries', 'delete_entry'),
    ]) {
      expect(
        LabArchivesClient.isReadOnlyElnOperation(endpoint.$1, endpoint.$2),
        isFalse,
      );
      expect(
        () => LabArchivesClient.assertReadOnlyElnOperation(
          apiClass: endpoint.$1,
          method: endpoint.$2,
        ),
        throwsA(isA<LabArchivesException>()),
      );
    }
  });

  test('backup endpoint refuses parameters that weaken preservation', () {
    expect(
      () => LabArchivesClient.assertReadOnlyElnOperation(
        apiClass: 'notebooks',
        method: 'notebook_backup',
        paramKeys: const ['uid', 'nbid', 'json'],
      ),
      returnsNormally,
    );

    expect(
      () => LabArchivesClient.assertReadOnlyElnOperation(
        apiClass: 'notebooks',
        method: 'notebook_backup',
        paramKeys: const ['uid', 'nbid', 'json', 'no_attachments'],
      ),
      throwsA(isA<LabArchivesException>()),
    );
  });

  test(
    'production LabArchives client has no mutable HTTP verbs or endpoints',
    () {
      final files = Directory('lib')
          .listSync(recursive: true)
          .whereType<File>()
          .where((file) => file.path.endsWith('.dart'))
          .toList();
      final labArchivesNetworkText = files
          .where(
            (file) =>
                file.path.endsWith('labarchives_client.dart') ||
                file.readAsStringSync().contains('api.labarchives-gov.com'),
          )
          .map((file) => file.readAsStringSync())
          .join('\n');

      for (final forbidden in const [
        '.postUrl(',
        '.putUrl(',
        '.patchUrl(',
        '.deleteUrl(',
        'openUrl(',
        '/api/entries/',
      ]) {
        expect(
          labArchivesNetworkText,
          isNot(contains(forbidden)),
          reason: forbidden,
        );
      }
    },
  );

  test('synthetic notebook seeder is locked behind a double opt-in', () {
    final text = File(
      'scripts/labarchives_seed_bio_test_notebook.py',
    ).readAsStringSync();

    expect(text, contains('BENCHVAULT_ALLOW_LABARCHIVES_TEST_WRITES'));
    expect(text, contains('YES_WRITE_SYNTHETIC_TEST_NOTEBOOK'));
    expect(
      text,
      contains('--i-understand-this-writes-to-labarchives-test-notebook'),
    );
    expect(text, contains('require_seed_write_enabled'));
    expect(text, contains('MUTATING_ELN_ENDPOINTS'));
  });
}
