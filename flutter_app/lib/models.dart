// Data models shared by the UI and RealBackend.
// Field names mirror the questctl --json contract in backend/CONTRACT.md.
// This app is Real mode only: there is no demo data anywhere.
// Quest 2 is the first-class target; features are labelled by model
// where they differ. Everything is local/offline: no account, no ads.
class QuestDevice {
  final String serial;
  final String state; // device | unauthorized | offline
  final String model;
  final String transport; // usb | wifi
  const QuestDevice({required this.serial, required this.state, required this.model, required this.transport});
  factory QuestDevice.fromJson(Map<String, dynamic> j) => QuestDevice(
        serial: (j['serial'] ?? '').toString(),
        state: (j['state'] ?? 'offline').toString(),
        model: (j['model'] ?? 'Quest').toString(),
        transport: (j['transport'] ?? 'usb').toString(),
      );
}

class DeviceInfo {
  final String model, serial, firmware, androidVersion, resolution, cpuAbi;
  final int batteryLevel, batteryTempC, storageUsedGb, storageTotalGb;
  final bool charging;
  const DeviceInfo({
    required this.model,
    required this.serial,
    required this.firmware,
    required this.androidVersion,
    required this.resolution,
    required this.cpuAbi,
    required this.batteryLevel,
    required this.batteryTempC,
    required this.storageUsedGb,
    required this.storageTotalGb,
    required this.charging,
  });
}

int? _optInt(dynamic v) => v is num ? v.toInt() : null;
String? _optStr(dynamic v) => v == null ? null : v.toString();

class QuestApp {
  final String package, label, version;
  final bool system;
  final String size; // legacy human string, kept for compat (usually empty now)
  final List<String> permissions;
  /// Local icon file from `apps icon` / `apps list --with-icons`.
  /// Null when no icon is cached yet (UI loads it lazily) or the app
  /// has no launcher icon at all (UI falls back to initials).
  final String? iconPath;
  // Sizes and details (bytes; null when the device could not report
  // them, e.g. data size without root). See backend/CONTRACT.md.
  final int? apkSizeBytes, dataSizeBytes, obbSizeBytes, totalSizeBytes;
  final int? versionCode, minSdk, targetSdk;
  final String? firstInstallTime, lastUpdateTime, installer;
  const QuestApp({
    required this.package,
    required this.label,
    required this.version,
    required this.system,
    this.size = '',
    this.permissions = const [],
    this.iconPath,
    this.apkSizeBytes,
    this.dataSizeBytes,
    this.obbSizeBytes,
    this.totalSizeBytes,
    this.versionCode,
    this.minSdk,
    this.targetSdk,
    this.firstInstallTime,
    this.lastUpdateTime,
    this.installer,
  });
  factory QuestApp.fromJson(Map<String, dynamic> j) => QuestApp(
        package: (j['package'] ?? '').toString(),
        label: (j['label'] ?? j['package'] ?? '').toString(),
        version: (j['version'] ?? '').toString(),
        system: j['system'] == true,
        iconPath: (j['icon_path'] as String?)?.isNotEmpty == true ? j['icon_path'] as String : null,
        apkSizeBytes: _optInt(j['apk_size_bytes']),
        dataSizeBytes: _optInt(j['data_size_bytes']),
        obbSizeBytes: _optInt(j['obb_size_bytes']),
        totalSizeBytes: _optInt(j['total_size_bytes']),
        versionCode: _optInt(j['version_code']),
        minSdk: _optInt(j['min_sdk']),
        targetSdk: _optInt(j['target_sdk']),
        firstInstallTime: _optStr(j['first_install_time']),
        lastUpdateTime: _optStr(j['last_update_time']),
        installer: _optStr(j['installer']),
        permissions: ((j['permissions'] as List?) ?? []).map((e) => e.toString()).toList(),
      );
  QuestApp copyWith({String? label, String? iconPath}) => QuestApp(
        package: package,
        label: label ?? this.label,
        version: version,
        system: system,
        size: size,
        permissions: permissions,
        iconPath: iconPath ?? this.iconPath,
        apkSizeBytes: apkSizeBytes,
        dataSizeBytes: dataSizeBytes,
        obbSizeBytes: obbSizeBytes,
        totalSizeBytes: totalSizeBytes,
        versionCode: versionCode,
        minSdk: minSdk,
        targetSdk: targetSdk,
        firstInstallTime: firstInstallTime,
        lastUpdateTime: lastUpdateTime,
        installer: installer,
      );
}

/// Result of `apps icon --package <pkg>`: the real label and the
/// local path of the extracted launcher icon (PNG or WebP).
class AppIcon {
  final String package, label, iconPath, iconFile;
  const AppIcon({required this.package, required this.label, required this.iconPath, required this.iconFile});
  factory AppIcon.fromJson(Map<String, dynamic> j) => AppIcon(
        package: (j['package'] ?? '').toString(),
        label: (j['label'] ?? '').toString(),
        iconPath: (j['icon_path'] ?? '').toString(),
        iconFile: (j['icon_file'] ?? '').toString(),
      );
}

/// Full details for one app (`apps details`): everything in
/// QuestApp plus split APK paths, OBB files, and the data-size note.
/// Maker is deliberately absent: an APK stores no maker name.
class AppDetails {
  final String package, label, version;
  final bool system;
  final int? versionCode, minSdk, targetSdk;
  final String? firstInstallTime, lastUpdateTime, installer;
  final List<String> apkPaths, obbFiles, permissions;
  final int? apkSizeBytes, dataSizeBytes, obbSizeBytes, totalSizeBytes;
  final String? dataSizeNote, iconPath;
  const AppDetails({
    required this.package,
    required this.label,
    required this.version,
    required this.system,
    this.versionCode,
    this.minSdk,
    this.targetSdk,
    this.firstInstallTime,
    this.lastUpdateTime,
    this.installer,
    this.apkPaths = const [],
    this.obbFiles = const [],
    this.permissions = const [],
    this.apkSizeBytes,
    this.dataSizeBytes,
    this.obbSizeBytes,
    this.totalSizeBytes,
    this.dataSizeNote,
    this.iconPath,
  });
  factory AppDetails.fromJson(Map<String, dynamic> j) => AppDetails(
        package: (j['package'] ?? '').toString(),
        label: (j['label'] ?? j['package'] ?? '').toString(),
        version: (j['version'] ?? '').toString(),
        system: j['system'] == true,
        versionCode: _optInt(j['version_code']),
        minSdk: _optInt(j['min_sdk']),
        targetSdk: _optInt(j['target_sdk']),
        firstInstallTime: _optStr(j['first_install_time']),
        lastUpdateTime: _optStr(j['last_update_time']),
        installer: _optStr(j['installer']),
        apkPaths: ((j['apk_paths'] as List?) ?? []).map((e) => e.toString()).toList(),
        obbFiles: ((j['obb_files'] as List?) ?? []).map((e) => e.toString()).toList(),
        permissions: ((j['permissions'] as List?) ?? []).map((e) => e.toString()).toList(),
        apkSizeBytes: _optInt(j['apk_size_bytes']),
        dataSizeBytes: _optInt(j['data_size_bytes']),
        obbSizeBytes: _optInt(j['obb_size_bytes']),
        totalSizeBytes: _optInt(j['total_size_bytes']),
        dataSizeNote: _optStr(j['data_size_note']),
        iconPath: _optStr(j['icon_path']),
      );
}

class StepResult {
  final String item, message;
  final bool ok;
  const StepResult({required this.item, required this.message, required this.ok});
  factory StepResult.fromJson(Map<String, dynamic> j) => StepResult(
        item: (j['item'] ?? '').toString(),
        message: (j['message'] ?? '').toString(),
        ok: j['ok'] == true,
      );
}

List<StepResult> _steps(dynamic v) =>
    ((v as List?) ?? []).map((e) => StepResult.fromJson(e as Map<String, dynamic>)).toList();

/// One app/save backup folder (`apps backup-list`).
class BackupEntry {
  final String package, label, version, backupDate, path;
  final int totalSizeBytes, apkCount, obbCount;
  final bool hasData;
  const BackupEntry({
    required this.package,
    required this.label,
    required this.version,
    required this.backupDate,
    required this.path,
    required this.totalSizeBytes,
    required this.apkCount,
    required this.obbCount,
    required this.hasData,
  });
  factory BackupEntry.fromJson(Map<String, dynamic> j) => BackupEntry(
        package: (j['package'] ?? '').toString(),
        label: (j['label'] ?? j['package'] ?? '').toString(),
        version: (j['version'] ?? '').toString(),
        backupDate: (j['backup_date'] ?? '').toString(),
        path: (j['path'] ?? '').toString(),
        totalSizeBytes: _optInt(j['total_size_bytes']) ?? 0,
        apkCount: _optInt(j['apk_count']) ?? 0,
        obbCount: _optInt(j['obb_count']) ?? 0,
        hasData: j['has_data'] == true,
      );
}

/// Result of `apps backup` / `apps save-backup`.
class BackupReport {
  final String package, label, version, path, backupDate;
  final int totalSizeBytes;
  final bool ok;
  final List<StepResult> steps;
  const BackupReport({
    required this.package,
    required this.label,
    required this.version,
    required this.path,
    required this.backupDate,
    required this.totalSizeBytes,
    required this.ok,
    required this.steps,
  });
  factory BackupReport.fromJson(Map<String, dynamic> j) => BackupReport(
        package: (j['package'] ?? '').toString(),
        label: (j['label'] ?? j['package'] ?? '').toString(),
        version: (j['version'] ?? '').toString(),
        path: (j['path'] ?? '').toString(),
        backupDate: (j['backup_date'] ?? '').toString(),
        totalSizeBytes: _optInt(j['total_size_bytes']) ?? 0,
        ok: j['ok'] == true,
        steps: _steps(j['steps']),
      );
}

/// Result of `apps restore` / `apps save-restore` / `device restore`.
class RestoreReport {
  final String package, backupPath;
  final bool dryRun, ok;
  final List<StepResult> steps;
  const RestoreReport({
    required this.package,
    required this.backupPath,
    required this.dryRun,
    required this.ok,
    required this.steps,
  });
  factory RestoreReport.fromJson(Map<String, dynamic> j) => RestoreReport(
        package: (j['package'] ?? '').toString(),
        backupPath: (j['backup_path'] ?? j['backup'] ?? '').toString(),
        dryRun: j['dry_run'] == true,
        ok: j['ok'] == true,
        steps: _steps(j['steps']),
      );
}

/// One library entry: app backup, save backup, or imported APK.
/// All live in the one library folder
/// (~/.local/share/quest-companion/backups/).
class LibraryEntry {
  final String kind, source, package, label, version, dateAdded, path;
  final int? versionCode;
  final int sizeBytes, apkCount, obbCount;
  final String? sha256;
  final bool hasData;
  const LibraryEntry({
    required this.kind,
    required this.source,
    required this.package,
    required this.label,
    required this.version,
    required this.dateAdded,
    required this.path,
    this.versionCode,
    required this.sizeBytes,
    required this.apkCount,
    required this.obbCount,
    this.sha256,
    required this.hasData,
  });
  factory LibraryEntry.fromJson(Map<String, dynamic> j) => LibraryEntry(
        kind: (j['kind'] ?? 'app').toString(),
        source: (j['source'] ?? 'backup').toString(),
        package: (j['package'] ?? '').toString(),
        label: (j['label'] ?? j['package'] ?? '').toString(),
        version: (j['version'] ?? '').toString(),
        dateAdded: (j['date_added'] ?? '').toString(),
        path: (j['path'] ?? '').toString(),
        versionCode: _optInt(j['version_code']),
        sizeBytes: _optInt(j['size_bytes']) ?? 0,
        apkCount: _optInt(j['apk_count']) ?? 0,
        obbCount: _optInt(j['obb_count']) ?? 0,
        sha256: _optStr(j['sha256']),
        hasData: j['has_data'] == true,
      );
}

class GalleryEntry {
  final String name, path, kind, modified;
  final int sizeBytes;
  const GalleryEntry({required this.name, required this.path, required this.kind, required this.modified, required this.sizeBytes});
  factory GalleryEntry.fromJson(Map<String, dynamic> j) => GalleryEntry(
        name: (j['name'] ?? '').toString(),
        path: (j['path'] ?? '').toString(),
        kind: (j['kind'] ?? 'screenshot').toString(),
        modified: (j['modified'] ?? '').toString(),
        sizeBytes: _optInt(j['size_bytes']) ?? 0,
      );
}

class ShellResult {
  final String stdout, stderr;
  final int code;
  const ShellResult({required this.stdout, required this.stderr, required this.code});
}

class RootStatus {
  final bool rooted, suPresent, magiskPresent, singularityPresent;
  final String method;
  const RootStatus({required this.rooted, required this.method, required this.suPresent, required this.magiskPresent, required this.singularityPresent});
  factory RootStatus.fromJson(Map<String, dynamic> j) => RootStatus(
        rooted: j['rooted'] == true,
        method: (j['method'] ?? 'Not rooted').toString(),
        suPresent: j['su_present'] == true,
        magiskPresent: j['magisk_present'] == true,
        singularityPresent: j['singularity_present'] == true,
      );
  static const notRooted = RootStatus(rooted: false, method: 'Not rooted', suPresent: false, magiskPresent: false, singularityPresent: false);
}

class ControllersInfo {
  final List<String> names;
  final String note;
  const ControllersInfo({required this.names, required this.note});
  factory ControllersInfo.fromJson(Map<String, dynamic> j) => ControllersInfo(
        names: ((j['controllers'] as List?) ?? []).map((e) => ((e as Map)['name'] ?? '').toString()).toList(),
        note: (j['note'] ?? '').toString(),
      );
}

class UpdateBlockStatus {
  final bool blocked, rooted;
  final List<String> disabledPackages;
  const UpdateBlockStatus({required this.blocked, required this.rooted, required this.disabledPackages});
  factory UpdateBlockStatus.fromJson(Map<String, dynamic> j) => UpdateBlockStatus(
        blocked: j['blocked'] == true,
        rooted: j['rooted'] == true,
        disabledPackages: ((j['packages'] as List?) ?? [])
            .where((e) => (e as Map)['disabled'] == true)
            .map((e) => ((e as Map)['package'] ?? '').toString())
            .toList(),
      );
}

class WifiSetupResult {
  final bool connected;
  final String? ip, wirelessSerial, note;
  const WifiSetupResult({required this.connected, this.ip, this.wirelessSerial, this.note});
  factory WifiSetupResult.fromJson(Map<String, dynamic> j) => WifiSetupResult(
        connected: j['connected'] == true,
        ip: _optStr(j['ip']),
        wirelessSerial: _optStr(j['wireless_serial']),
        note: _optStr(j['note']),
      );
}

class DebugInfo {
  final String questctlVersion, adbVersion, backendPath;
  final bool scrcpyAvailable;
  final String? wifiIp;
  final RootStatus root;
  final DeviceInfo? device;
  const DebugInfo({
    required this.questctlVersion,
    required this.adbVersion,
    required this.backendPath,
    required this.scrcpyAvailable,
    this.wifiIp,
    required this.root,
    this.device,
  });
}

class DeviceBackupEntry {
  final String serial, backupDate, path;
  final int totalSizeBytes, appCount;
  const DeviceBackupEntry({required this.serial, required this.backupDate, required this.path, required this.totalSizeBytes, required this.appCount});
  factory DeviceBackupEntry.fromJson(Map<String, dynamic> j) => DeviceBackupEntry(
        serial: (j['serial'] ?? '').toString(),
        backupDate: (j['backup_date'] ?? '').toString(),
        path: (j['path'] ?? '').toString(),
        totalSizeBytes: _optInt(j['total_size_bytes']) ?? 0,
        appCount: _optInt(j['app_count']) ?? 0,
      );
}

class QuestFile {
  final String name, path;
  final bool isDir;
  final int size;
  const QuestFile({required this.name, required this.path, required this.isDir, required this.size});
  factory QuestFile.fromJson(Map<String, dynamic> j) => QuestFile(
        name: (j['name'] ?? '').toString(),
        path: (j['path'] ?? '').toString(),
        isDir: j['is_dir'] == true,
        size: (j['size'] is num) ? (j['size'] as num).toInt() : 0,
      );
}

class SettingProfile {
  final String name;
  final int refreshRate;
  final int cpuLevel;
  final int gpuLevel;
  final String resolution;
  final bool guardianPaused;
  const SettingProfile({required this.name, required this.refreshRate, required this.cpuLevel, required this.gpuLevel, required this.resolution, required this.guardianPaused});
}

class BackendResult {
  final bool ok;
  final String message;
  final Map<String, dynamic> data;
  const BackendResult({required this.ok, this.message = '', this.data = const {}});
}
