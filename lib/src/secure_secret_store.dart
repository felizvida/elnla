import 'dart:io';

class BenchVaultSecretServices {
  const BenchVaultSecretServices._();

  static const labArchives = 'BenchVault LabArchives GOV';
  static const openAi = 'BenchVault OpenAI';
}

class BenchVaultSecretAccounts {
  const BenchVaultSecretAccounts._();

  static const labArchivesAccessId = 'labarchives_gov_login_id';
  static const labArchivesAccessKey = 'labarchives_gov_access_key';
  static const openAiApiKey = 'openai_api_key';
}

abstract class SecureSecretStore {
  bool get isAvailable;

  String get storageLabel;

  Future<String?> read({required String service, required String account});

  Future<void> write({
    required String service,
    required String account,
    required String value,
  });

  Future<void> delete({required String service, required String account});
}

class DisabledSecretStore implements SecureSecretStore {
  const DisabledSecretStore();

  @override
  bool get isAvailable => false;

  @override
  String get storageLabel => 'local files';

  @override
  Future<String?> read({
    required String service,
    required String account,
  }) async {
    return null;
  }

  @override
  Future<void> write({
    required String service,
    required String account,
    required String value,
  }) async {}

  @override
  Future<void> delete({
    required String service,
    required String account,
  }) async {}
}

class MacOSKeychainSecretStore implements SecureSecretStore {
  const MacOSKeychainSecretStore();

  static bool get isSupported => Platform.isMacOS;

  @override
  bool get isAvailable => isSupported;

  @override
  String get storageLabel => 'macOS Keychain';

  @override
  Future<String?> read({
    required String service,
    required String account,
  }) async {
    if (!isAvailable) {
      return null;
    }
    final result = await Process.run('security', [
      'find-generic-password',
      '-a',
      account,
      '-s',
      service,
      '-w',
    ]);
    if (result.exitCode != 0) {
      return null;
    }
    final value = '${result.stdout}'.trim();
    return value.isEmpty ? null : value;
  }

  @override
  Future<void> write({
    required String service,
    required String account,
    required String value,
  }) async {
    if (!isAvailable) {
      return;
    }
    final result = await Process.run('security', [
      'add-generic-password',
      '-a',
      account,
      '-s',
      service,
      '-w',
      value,
      '-U',
    ]);
    if (result.exitCode != 0) {
      throw StateError('Could not write secret to macOS Keychain.');
    }
  }

  @override
  Future<void> delete({
    required String service,
    required String account,
  }) async {
    if (!isAvailable) {
      return;
    }
    await Process.run('security', [
      'delete-generic-password',
      '-a',
      account,
      '-s',
      service,
    ]);
  }
}

class InMemorySecureSecretStore implements SecureSecretStore {
  final Map<String, String> _values = <String, String>{};

  @override
  bool get isAvailable => true;

  @override
  String get storageLabel => 'test secure store';

  @override
  Future<String?> read({
    required String service,
    required String account,
  }) async {
    return _values[_key(service, account)];
  }

  @override
  Future<void> write({
    required String service,
    required String account,
    required String value,
  }) async {
    _values[_key(service, account)] = value;
  }

  @override
  Future<void> delete({
    required String service,
    required String account,
  }) async {
    _values.remove(_key(service, account));
  }

  String _key(String service, String account) => '$service::$account';
}
