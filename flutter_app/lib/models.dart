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
  // `ready`, not `ok`: the backend envelope already uses `ok` for
  // "the command ran", so a report-level `ok` would be clobbered
  // by it and the UI could never see a dry run that found problems.
  final bool dryRun, ready;
  final List<StepResult> steps;
  const RestoreReport({
    required this.package,
    required this.backupPath,
    required this.dryRun,
    required this.ready,
    required this.steps,
  });
  factory RestoreReport.fromJson(Map<String, dynamic> j) => RestoreReport(
        package: (j['package'] ?? '').toString(),
        backupPath: (j['backup_path'] ?? j['backup'] ?? '').toString(),
        dryRun: j['dry_run'] == true,
        ready: j['ready'] == true,
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
  /// True when the names are the last ones seen, not ones awake now.
  final bool asleep;
  /// When they were last seen awake, or null when never seen.
  final String? lastSeen;
  const ControllersInfo({required this.names, required this.note, this.asleep = false, this.lastSeen});
  factory ControllersInfo.fromJson(Map<String, dynamic> j) => ControllersInfo(
        names: ((j['controllers'] as List?) ?? []).map((e) => ((e as Map)['name'] ?? '').toString()).toList(),
        note: (j['note'] ?? '').toString(),
        asleep: j['asleep'] == true,
        lastSeen: (j['last_seen'] as String?)?.isEmpty == true ? null : j['last_seen'] as String?,
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

class HomeEntry {
  final String component, package, label;
  final bool isCurrent;
  const HomeEntry({required this.component, required this.package, required this.label, required this.isCurrent});
  factory HomeEntry.fromJson(Map<String, dynamic> j) => HomeEntry(
        component: (j['component'] ?? '').toString(),
        package: (j['package'] ?? '').toString(),
        label: (j['label'] ?? '').toString(),
        isCurrent: j['is_current'] == true,
      );
}

class SnapshotEntry {
  final String serial, name, createdDate, path;
  final int totalSizeBytes, appCount;
  const SnapshotEntry({required this.serial, required this.name, required this.createdDate, required this.path, required this.totalSizeBytes, required this.appCount});
  factory SnapshotEntry.fromJson(Map<String, dynamic> j) => SnapshotEntry(
        serial: (j['serial'] ?? '').toString(),
        name: (j['name'] ?? '').toString(),
        createdDate: (j['created_date'] ?? '').toString(),
        path: (j['path'] ?? '').toString(),
        totalSizeBytes: _optInt(j['total_size_bytes']) ?? 0,
        appCount: _optInt(j['app_count']) ?? 0,
      );
}

class HealthInfo {
  final String serial, model, firmware;
  final int batteryLevel, batteryTempC, batteryVoltageMv;
  final String batteryHealth, batteryStatus;
  final bool charging;
  final int sdcardTotalKb, sdcardUsedKb, sdcardFreeKb;
  final int dataTotalKb, dataUsedKb, dataFreeKb;
  final String? uptime, lastBackup;
  int get sdcardUsedGb => (sdcardUsedKb / 1024 / 1024).round();
  int get sdcardTotalGb => (sdcardTotalKb / 1024 / 1024).round();
  int get dataUsedGb => (dataUsedKb / 1024 / 1024).round();
  int get dataTotalGb => (dataTotalKb / 1024 / 1024).round();
  const HealthInfo({
    required this.serial,
    required this.model,
    required this.firmware,
    required this.batteryLevel,
    required this.batteryTempC,
    required this.batteryVoltageMv,
    required this.batteryHealth,
    required this.batteryStatus,
    required this.charging,
    required this.sdcardTotalKb,
    required this.sdcardUsedKb,
    required this.sdcardFreeKb,
    required this.dataTotalKb,
    required this.dataUsedKb,
    required this.dataFreeKb,
    this.uptime,
    this.lastBackup,
  });
  factory HealthInfo.fromJson(Map<String, dynamic> j) {
    final battery = (j['battery'] as Map?) ?? {};
    final sd = (j['storage_sdcard'] as Map?) ?? {};
    final data = (j['storage_data'] as Map?) ?? {};
    int kb(dynamic v) => (v is num) ? v.toInt() : 0;
    final status = (battery['status'] ?? '').toString().toLowerCase();
    final plugged = (battery['plugged'] ?? '').toString();
    return HealthInfo(
      serial: (j['serial'] ?? '').toString(),
      model: (j['model'] ?? '').toString(),
      firmware: (j['firmware'] ?? '').toString(),
      batteryLevel: _optInt(battery['level']) ?? 0,
      batteryTempC: (battery['temperature_c'] is num) ? (battery['temperature_c'] as num).round() : 0,
      batteryVoltageMv: _optInt(battery['voltage_mv']) ?? 0,
      batteryHealth: (battery['health'] ?? '').toString(),
      batteryStatus: (battery['status'] ?? '').toString(),
      charging: status == 'charging' || status == 'full' || plugged.isNotEmpty,
      sdcardTotalKb: kb(sd['total_kb']),
      sdcardUsedKb: kb(sd['used_kb']),
      sdcardFreeKb: kb(sd['free_kb']),
      dataTotalKb: kb(data['total_kb']),
      dataUsedKb: kb(data['used_kb']),
      dataFreeKb: kb(data['free_kb']),
      uptime: _optStr(j['uptime']),
      lastBackup: _optStr(j['last_backup']),
    );
  }
}

class BatterySample {
  final int time, level;
  final bool charging;
  const BatterySample({required this.time, required this.level, required this.charging});
  factory BatterySample.fromJson(Map<String, dynamic> j) => BatterySample(
        time: (j['time'] is num) ? (j['time'] as num).toInt() : 0,
        level: (j['level'] is num) ? (j['level'] as num).toInt() : 0,
        charging: j['charging'] == true,
      );
}

class AppUsage {
  final String package;
  final int totalForegroundMs;
  final int? lastUsedMs;
  const AppUsage({required this.package, required this.totalForegroundMs, this.lastUsedMs});
  factory AppUsage.fromJson(Map<String, dynamic> j) => AppUsage(
        package: (j['package'] ?? '').toString(),
        totalForegroundMs: (j['total_foreground_ms'] is num) ? (j['total_foreground_ms'] as num).toInt() : 0,
        lastUsedMs: (j['last_used_ms'] is num) ? (j['last_used_ms'] as num).toInt() : null,
      );
}

class BatteryHistory {
  final String serial;
  final int batteryLevel;
  final bool charging;
  final List<BatterySample> samples;
  final List<AppUsage> topApps;
  const BatteryHistory({required this.serial, required this.batteryLevel, required this.charging, required this.samples, required this.topApps});
  factory BatteryHistory.fromJson(Map<String, dynamic> j) {
    final battery = (j['battery'] as Map?) ?? {};
    final status = (battery['status'] ?? '').toString().toLowerCase();
    final plugged = (battery['plugged'] ?? '').toString();
    return BatteryHistory(
      serial: (j['serial'] ?? '').toString(),
      batteryLevel: _optInt(battery['level']) ?? 0,
      charging: status == 'charging' || status == 'full' || plugged.isNotEmpty,
      samples: ((j['samples'] as List?) ?? []).map((s) => BatterySample.fromJson(s as Map<String, dynamic>)).toList(),
      topApps: ((j['top_apps'] as List?) ?? []).map((a) => AppUsage.fromJson(a as Map<String, dynamic>)).toList(),
    );
  }
}

class ApkAnalysis {
  final String path, file;
  final int fileSizeBytes;
  final String sha256;
  final String? package, label, versionName, signatureSha256;
  final int? versionCode, minSdk, targetSdk;
  final List<String> permissions, features, abis;
  final bool is64Bit, signatureChecked;
  final int nativeLibBytes, nativeLibCount, dexBytes, assetsBytes, resBytes;
  final List<String> notes;
  const ApkAnalysis({
    required this.path,
    required this.file,
    required this.fileSizeBytes,
    required this.sha256,
    required this.package,
    required this.label,
    required this.versionName,
    required this.versionCode,
    required this.minSdk,
    required this.targetSdk,
    required this.permissions,
    required this.features,
    required this.abis,
    required this.is64Bit,
    required this.signatureChecked,
    required this.nativeLibBytes,
    required this.nativeLibCount,
    required this.dexBytes,
    required this.assetsBytes,
    required this.resBytes,
    required this.signatureSha256,
    required this.notes,
  });
  factory ApkAnalysis.fromJson(Map<String, dynamic> j) => ApkAnalysis(
        path: (j['path'] ?? '').toString(),
        file: (j['file'] ?? '').toString(),
        fileSizeBytes: _optInt(j['file_size_bytes']) ?? 0,
        sha256: (j['sha256'] ?? '').toString(),
        package: _optStr(j['package']),
        label: _optStr(j['label']),
        versionName: _optStr(j['version_name']),
        versionCode: _optInt(j['version_code']),
        minSdk: _optInt(j['min_sdk']),
        targetSdk: _optInt(j['target_sdk']),
        permissions: ((j['permissions'] as List?) ?? []).map((e) => e.toString()).toList(),
        features: ((j['features'] as List?) ?? []).map((e) => e.toString()).toList(),
        abis: ((j['abis'] as List?) ?? []).map((e) => e.toString()).toList(),
        is64Bit: j['is_64_bit'] == true,
        signatureChecked: j['signature_checked'] == true,
        nativeLibBytes: _optInt(j['native_lib_bytes']) ?? 0,
        nativeLibCount: _optInt(j['native_lib_count']) ?? 0,
        dexBytes: _optInt(j['dex_bytes']) ?? 0,
        assetsBytes: _optInt(j['assets_bytes']) ?? 0,
        resBytes: _optInt(j['res_bytes']) ?? 0,
        signatureSha256: _optStr(j['signature_sha256']),
        notes: ((j['notes'] as List?) ?? []).map((e) => e.toString()).toList(),
      );
}

class PreflightCheck {
  final String name, detail;
  final bool ok;
  const PreflightCheck({required this.name, required this.detail, required this.ok});
  factory PreflightCheck.fromJson(Map<String, dynamic> j) => PreflightCheck(
        name: (j['name'] ?? '').toString(),
        detail: (j['detail'] ?? '').toString(),
        ok: j['ok'] == true,
      );
}

class SingularityPreflight {
  final List<PreflightCheck> checks;
  // `ready`, not `ok`: the backend envelope already uses `ok` for
  // "the command ran", so a report-level `ok` would be clobbered
  // by it and the wizard could never see a failed preflight.
  final bool ready;
  final String summary;
  const SingularityPreflight({required this.checks, required this.ready, required this.summary});
  factory SingularityPreflight.fromJson(Map<String, dynamic> j) => SingularityPreflight(
        checks: ((j['checks'] as List?) ?? []).map((e) => PreflightCheck.fromJson(e as Map<String, dynamic>)).toList(),
        ready: j['ready'] == true,
        summary: (j['summary'] ?? '').toString(),
      );
}

class SingularityDownload {
  final String id, name, detail, source, version, onHeadset;
  final bool downloadable, downloaded;
  final String? file, sha256;
  final int sizeBytes;
  const SingularityDownload({required this.id, required this.name, required this.detail, required this.source, required this.version, required this.onHeadset, required this.downloadable, required this.downloaded, this.file, this.sha256, required this.sizeBytes});
  factory SingularityDownload.fromJson(Map<String, dynamic> j) => SingularityDownload(
        id: (j['id'] ?? '').toString(),
        name: (j['name'] ?? '').toString(),
        detail: (j['detail'] ?? '').toString(),
        source: (j['source'] ?? '').toString(),
        version: (j['version'] ?? '').toString(),
        onHeadset: (j['on_headset'] ?? '').toString(),
        downloadable: j['downloadable'] == true,
        downloaded: j['downloaded'] == true,
        file: j['file']?.toString(),
        sha256: j['sha256']?.toString(),
        sizeBytes: _optInt(j['size_bytes']) ?? 0,
      );
}

class FridaStatusInfo {
  final bool downloaded, pushed, running;
  final String? file, sha256;
  final int sizeBytes;
  const FridaStatusInfo({required this.downloaded, required this.pushed, required this.running, this.file, this.sha256, required this.sizeBytes});
  factory FridaStatusInfo.fromJson(Map<String, dynamic> j) => FridaStatusInfo(
        downloaded: j['downloaded'] == true,
        pushed: j['pushed'] == true,
        running: j['running'] == true,
        file: j['file']?.toString(),
        sha256: j['sha256']?.toString(),
        sizeBytes: _optInt(j['size_bytes']) ?? 0,
      );
}

class HostsStatusInfo {
  final bool downloaded, applied;
  final String? file, sha256;
  final int domains, sizeBytes, systemLines, moduleDomains;
  const HostsStatusInfo({required this.downloaded, required this.applied, this.file, this.sha256, required this.domains, required this.sizeBytes, required this.systemLines, required this.moduleDomains});
  factory HostsStatusInfo.fromJson(Map<String, dynamic> j) => HostsStatusInfo(
        downloaded: j['downloaded'] == true,
        applied: j['applied'] == true,
        file: j['file']?.toString(),
        sha256: j['sha256']?.toString(),
        domains: _optInt(j['domains']) ?? 0,
        sizeBytes: _optInt(j['size_bytes']) ?? 0,
        systemLines: _optInt(j['system_lines']) ?? 0,
        moduleDomains: _optInt(j['module_domains']) ?? 0,
      );
}

class OtaStatusInfo {
  final bool blocked, updaterDisabled;
  final String? downloadUrl, updateServerUrl;
  const OtaStatusInfo({required this.blocked, required this.updaterDisabled, this.downloadUrl, this.updateServerUrl});
  factory OtaStatusInfo.fromJson(Map<String, dynamic> j) => OtaStatusInfo(
        blocked: j['blocked'] == true,
        updaterDisabled: j['updater_disabled'] == true,
        downloadUrl: j['download_url']?.toString(),
        updateServerUrl: j['update_server_url']?.toString(),
      );
}

class UxpSetting {
  final String key, label, detail;
  final String? value;
  final bool isToggle, enabled;
  const UxpSetting({required this.key, required this.label, required this.detail, this.value, required this.isToggle, required this.enabled});
  factory UxpSetting.fromJson(Map<String, dynamic> j) => UxpSetting(
        key: (j['key'] ?? '').toString(),
        label: (j['label'] ?? '').toString(),
        detail: (j['detail'] ?? '').toString(),
        value: j['value']?.toString(),
        isToggle: j['is_toggle'] == true,
        enabled: j['enabled'] == true,
      );
}

class HomeAppStatus {
  final String id, name, package, detail, source;
  final bool installed, updateAvailable, downloaded;
  final String? installedVersion, latestVersion, file, sha256;
  final int sizeBytes;
  const HomeAppStatus({required this.id, required this.name, required this.package, required this.detail, required this.source, required this.installed, required this.updateAvailable, required this.downloaded, this.installedVersion, this.latestVersion, this.file, this.sha256, required this.sizeBytes});
  factory HomeAppStatus.fromJson(Map<String, dynamic> j) => HomeAppStatus(
        id: (j['id'] ?? '').toString(),
        name: (j['name'] ?? '').toString(),
        package: (j['package'] ?? '').toString(),
        detail: (j['detail'] ?? '').toString(),
        source: (j['source'] ?? '').toString(),
        installed: j['installed'] == true,
        updateAvailable: j['update_available'] == true,
        downloaded: j['downloaded'] == true,
        installedVersion: j['installed_version']?.toString(),
        latestVersion: j['latest_version']?.toString(),
        file: j['file']?.toString(),
        sha256: j['sha256']?.toString(),
        sizeBytes: _optInt(j['size_bytes']) ?? 0,
      );
}

class PathsInfo {
  final String backupRoot, recordingsRoot, configFile;
  final bool backupRootIsDefault, recordingsRootIsDefault;
  const PathsInfo({required this.backupRoot, required this.recordingsRoot, required this.configFile, required this.backupRootIsDefault, required this.recordingsRootIsDefault});
  factory PathsInfo.fromJson(Map<String, dynamic> j) => PathsInfo(
        backupRoot: (j['backup_root'] ?? '').toString(),
        recordingsRoot: (j['recordings_root'] ?? '').toString(),
        configFile: (j['config_file'] ?? '').toString(),
        backupRootIsDefault: j['backup_root_is_default'] == true,
        recordingsRootIsDefault: j['recordings_root_is_default'] == true,
      );
}

class MirrorSettings {
  final String usbQuality, wifiQuality;
  const MirrorSettings({required this.usbQuality, required this.wifiQuality});
  factory MirrorSettings.fromJson(Map<String, dynamic> j) => MirrorSettings(
        usbQuality: (j['usb_quality'] ?? 'balanced').toString(),
        wifiQuality: (j['wifi_quality'] ?? 'performance').toString(),
      );
}
