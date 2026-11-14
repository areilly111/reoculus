// Data models shared by the UI and RealBackend.
// Field names mirror the questctl --json contract in backend/CONTRACT.md.
// This app is Real mode only: there is no demo data anywhere.
// Quest 2 is the first-class target; features are labelled by model
// where they differ. Everything is local/offline: no account, no ads.
// `headsetModel` is the backend-classified slug (quest1, quest2,
// quest3, quest3s, questpro, unknown); use headsetDisplayName for
// the name shown to the user, it falls back to the raw model.
/// Friendly name for a headset model slug (quest1 becomes Quest 1).
/// Unknown slugs fall back to the raw model string.
String headsetDisplayName(String headsetModel, String model) {
  switch (headsetModel) {
    case 'quest1':
      return 'Quest 1';
    case 'quest2':
      return 'Quest 2';
    case 'quest3':
      return 'Quest 3';
    case 'quest3s':
      return 'Quest 3S';
    case 'questpro':
      return 'Quest Pro';
    default:
      return model.isEmpty ? 'Unknown headset' : model;
  }
}

// ---- Headsets ----
/// One headset adb can see: its serial, state, model and how it is
/// connected (usb or wifi).
class QuestDevice {
  final String serial;
  final String state; // device | unauthorized | offline
  final String model;
  final String device; // codename (monterey, hollywood, ...), may be empty
  final String headsetModel; // quest1, quest2, ... unknown
  final String transport; // usb | wifi
  const QuestDevice({required this.serial, required this.state, required this.model, this.device = '', this.headsetModel = 'unknown', required this.transport});
  /// Name shown in the UI: the friendly model name, or the raw model
  /// when unknown.
  String get displayName => headsetDisplayName(headsetModel, model);
  factory QuestDevice.fromJson(Map<String, dynamic> j) => QuestDevice(
        serial: (j['serial'] ?? '').toString(),
        state: (j['state'] ?? 'offline').toString(),
        model: (j['model'] ?? 'Quest').toString(),
        device: (j['device'] ?? '').toString(),
        headsetModel: (j['headset_model'] ?? 'unknown').toString(),
        transport: (j['transport'] ?? 'usb').toString(),
      );
}

/// Full details for one headset: model, firmware, battery and storage.
class DeviceInfo {
  final String model, serial, firmware, androidVersion, resolution, cpuAbi;
  final String headsetModel; // quest1, quest2, ... unknown
  final bool supportsSingularity; // false on Quest 1
  final bool supportsHomeSwitcher; // false on Quest 1
  final int batteryLevel, batteryTempC, storageUsedGb, storageTotalGb;
  final bool charging;
  /// Battery health from dumpsys ("Good", "Overheat", ...), '' when unknown.
  final String batteryHealth;
  /// Battery voltage in mV, 0 when unknown.
  final int batteryVoltageMv;
  /// Screen density in dpi, 0 when unknown.
  final int densityDpi;
  /// The headset's own Wi-Fi (wlan0) IPv4 address, when it has one.
  /// Used to spot that a USB entry and a Wi-Fi entry are the same
  /// headset, so the Devices screen can show one card, not two.
  final String? wifiIp;
  const DeviceInfo({
    required this.model,
    required this.serial,
    required this.firmware,
    required this.androidVersion,
    required this.resolution,
    required this.cpuAbi,
    this.headsetModel = 'unknown',
    this.supportsSingularity = true,
    this.supportsHomeSwitcher = true,
    required this.batteryLevel,
    required this.batteryTempC,
    required this.storageUsedGb,
    required this.storageTotalGb,
    required this.charging,
    this.batteryHealth = '',
    this.batteryVoltageMv = 0,
    this.densityDpi = 0,
    this.wifiIp,
  });
  /// Name shown in the UI: the friendly model name, or the raw model
  /// when unknown.
  String get displayName => headsetDisplayName(headsetModel, model);
  /// True for a Quest 1. The Quest 1 tops out at 72 Hz and cannot run
  /// Singularity or the home switcher.
  bool get isQuest1 => headsetModel == 'quest1';
  /// Free space in GB.
  int get storageFreeGb => storageTotalGb - storageUsedGb;
}

/// The headset's own config file (/sdcard/ReOculus/headset.cfg),
/// read on connect so Linux and Android show the same custom name.
/// The file holds ONLY the name: everything else (model, settings,
/// apps) the app reads live from the headset, so there is nothing
/// to sync. `present` is false when the headset has no custom name.
class HeadsetConfig {
  final bool present;
  final String? name;
  const HeadsetConfig({
    required this.present,
    this.name,
  });
  factory HeadsetConfig.fromJson(Map<String, dynamic> j) => HeadsetConfig(
        present: j['present'] == true,
        name: (j['name'] as String?)?.isEmpty == true ? null : j['name'] as String?,
      );
  static const absent = HeadsetConfig(present: false);
}

/// A JSON number as an int, or null when it is missing or not a number.
int? _optInt(dynamic v) => v is num ? v.toInt() : null;
/// A JSON value as a string, or null when it is missing.
String? _optStr(dynamic v) => v == null ? null : v.toString();

// ---- Apps ----
/// One app installed on the headset, with its sizes and install details
/// when the headset could report them.
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
  /// Same app, with a new label and/or icon path. Used when the real
  /// label or icon arrives after the list.
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

/// One step of a backup or restore: what it did, and whether it worked.
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

/// Parse a JSON list into StepResults. Missing or bad input becomes
/// an empty list, never a crash.
List<StepResult> _steps(dynamic v) =>
    ((v as List?) ?? []).map((e) => StepResult.fromJson(e as Map<String, dynamic>)).toList();

// ---- Backups, library and gallery ----
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

/// One screenshot or recording in the gallery folder.
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

/// The output of one shell command run on the headset.
class ShellResult {
  final String stdout, stderr;
  final int code;
  const ShellResult({required this.stdout, required this.stderr, required this.code});
}

// ---- Root, controllers and updates ----
/// How rooted the headset is: which method, and which root pieces are present.
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

/// The paired controllers. names can be the last ones seen, not ones
/// awake now: controllers sleep fast, so asleep says whether they were
/// awake when last seen.
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

/// Is the system updater disabled on the headset, and which updater
/// packages are disabled.
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

/// The result of the automatic Wi-Fi setup: did it connect, and on
/// which IP.
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

/// Everything the Help screen shows about this setup: versions,
/// backend path, root state, device info.
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

/// One whole-headset backup on this computer.
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

/// One file or folder on the headset.
class QuestFile {
  final String name, path;
  final bool isDir;
  final int size;
  /// Last-modified date from `ls -la`, as printed by the headset
  /// (ISO date or "Nov 13 12:00"), '' when unknown.
  final String modified;
  const QuestFile({required this.name, required this.path, required this.isDir, required this.size, this.modified = ''});
  factory QuestFile.fromJson(Map<String, dynamic> j) => QuestFile(
        name: (j['name'] ?? '').toString(),
        path: (j['path'] ?? '').toString(),
        isDir: j['is_dir'] == true,
        size: (j['size'] is num) ? (j['size'] as num).toInt() : 0,
        modified: (j['modified'] ?? '').toString(),
      );
}

/// A named settings profile: refresh rate, CPU/GPU level,
/// resolution, guardian pause.
class SettingProfile {
  final String name;
  final int refreshRate;
  final int cpuLevel;
  final int gpuLevel;
  final String resolution;
  final bool guardianPaused;
  const SettingProfile({required this.name, required this.refreshRate, required this.cpuLevel, required this.gpuLevel, required this.resolution, required this.guardianPaused});
}

/// The result of one backend call: did it work, and the message
/// to show.
class BackendResult {
  final bool ok;
  final String message;
  final Map<String, dynamic> data;
  const BackendResult({required this.ok, this.message = '', this.data = const {}});
}

/// One home launcher on the headset, and whether it is the one in
/// use now.
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

// ---- Snapshots and health ----
/// One saved whole-headset snapshot on this computer.
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

/// Battery, storage and uptime for one headset. Storage arrives in
/// KiB; the Gb getters below convert it.
class HealthInfo {
  final String serial, model, firmware;
  final int batteryLevel, batteryTempC, batteryVoltageMv;
  final String batteryHealth, batteryStatus;
  final bool charging;
  final int sdcardTotalKb, sdcardUsedKb, sdcardFreeKb;
  final int dataTotalKb, dataUsedKb, dataFreeKb;
  final String? uptime, lastBackup;
  /// Used sdcard space in GB (the backend reports KiB).
  int get sdcardUsedGb => (sdcardUsedKb / 1024 / 1024).round();
  /// Total sdcard space in GB (the backend reports KiB).
  int get sdcardTotalGb => (sdcardTotalKb / 1024 / 1024).round();
  /// Used data-partition space in GB (the backend reports KiB).
  int get dataUsedGb => (dataUsedKb / 1024 / 1024).round();
  /// Total data-partition space in GB (the backend reports KiB).
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
    // A JSON number as an int, or 0 when it is missing or not a number.
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

/// One battery reading: when, what level, and whether it was charging.
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

/// How long one app spent in the foreground, and when it was last used.
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

/// Battery level over time, plus the apps that used the most
/// foreground time.
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

/// What an APK file on this computer contains: package, version,
/// permissions, native libs, signature.
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

/// One preflight check before rooting: its name, detail, and whether
/// it passed.
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

// ---- Singularity downloads ----
/// One Singularity file (Magisk, frida, hosts, and the rest): what it is,
/// where it comes from, and whether it is already downloaded.
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

/// Is the frida server downloaded, pushed to the headset, and running.
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

/// Is the ad-blocking hosts file downloaded and applied on the headset.
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

/// Is the system update blocked on the headset.
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

/// One Singularity UXP setting: its key, label, and current value.
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

/// One downloadable home app: what it is, whether it is installed,
/// and whether an update is waiting.
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

/// Where backups and recordings live on this computer, and whether
/// each is still the default.
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

/// Saved mirror quality for USB and Wi-Fi, and whether the mirror
/// auto-restarts.
class MirrorSettings {
  final String usbQuality, wifiQuality;
  final bool autoRestart;
  const MirrorSettings({required this.usbQuality, required this.wifiQuality, this.autoRestart = true});
  factory MirrorSettings.fromJson(Map<String, dynamic> j) => MirrorSettings(
        usbQuality: (j['usb_quality'] ?? 'balanced').toString(),
        wifiQuality: (j['wifi_quality'] ?? 'performance').toString(),
        autoRestart: j['auto_restart'] != false,
      );
}

// ---- WiVRn ----
/// One PC game or app registered with WiVRn.
class WivrnApp {
  final String file, name, exec, icon;
  const WivrnApp({required this.file, required this.name, required this.exec, required this.icon});
  factory WivrnApp.fromJson(Map<String, dynamic> j) => WivrnApp(
        file: (j['file'] ?? '').toString(),
        name: (j['name'] ?? '').toString(),
        exec: (j['exec'] ?? '').toString(),
        icon: (j['icon'] ?? '').toString(),
      );
}

/// The headset's WiVRn client settings (client.json on the
/// headset). Bitrate is in Mbps here; the backend converts to
/// bitrate_bps. preferredRefreshRate 0 means Auto. codec "auto"
/// means the key is absent.
class WivrnClientSettings {
  final bool available;
  final String package, note, codec;
  final int bitrateMbps, bitDepth;
  final double resolutionScale, preferredRefreshRate;
  final bool passthroughEnabled, overrideFoveationEnable, highPowerMode, forwardKeyboard, forwardMouse, forwardGamepad;
  const WivrnClientSettings({
    required this.available,
    required this.package,
    required this.note,
    required this.bitrateMbps,
    required this.resolutionScale,
    required this.preferredRefreshRate,
    required this.codec,
    required this.bitDepth,
    required this.passthroughEnabled,
    required this.overrideFoveationEnable,
    required this.highPowerMode,
    required this.forwardKeyboard,
    required this.forwardMouse,
    required this.forwardGamepad,
  });
  factory WivrnClientSettings.fromJson(Map<String, dynamic> j) => WivrnClientSettings(
        available: j['available'] == true,
        package: (j['package'] ?? '').toString(),
        note: (j['note'] ?? '').toString(),
        bitrateMbps: (j['bitrate_mbps'] as num?)?.toInt() ?? 50,
        resolutionScale: (j['resolution_scale'] as num?)?.toDouble() ?? 1.2,
        preferredRefreshRate: (j['preferred_refresh_rate'] as num?)?.toDouble() ?? 0,
        codec: (j['codec'] ?? 'auto').toString(),
        bitDepth: (j['bit_depth'] as num?)?.toInt() ?? 10,
        passthroughEnabled: j['passthrough_enabled'] == true,
        overrideFoveationEnable: j['override_foveation_enable'] == true,
        highPowerMode: j['high_power_mode'] != false,
        forwardKeyboard: j['forward_keyboard'] == true,
        forwardMouse: j['forward_mouse'] == true,
        forwardGamepad: j['forward_gamepad'] == true,
      );
  /// Same settings, with the given fields replaced. Used by the PC VR
  /// screen while editing.
  WivrnClientSettings copyWith({
    bool? available,
    String? package,
    String? note,
    int? bitrateMbps,
    double? resolutionScale,
    double? preferredRefreshRate,
    String? codec,
    int? bitDepth,
    bool? passthroughEnabled,
    bool? overrideFoveationEnable,
    bool? highPowerMode,
    bool? forwardKeyboard,
    bool? forwardMouse,
    bool? forwardGamepad,
  }) =>
      WivrnClientSettings(
        available: available ?? this.available,
        package: package ?? this.package,
        note: note ?? this.note,
        bitrateMbps: bitrateMbps ?? this.bitrateMbps,
        resolutionScale: resolutionScale ?? this.resolutionScale,
        preferredRefreshRate: preferredRefreshRate ?? this.preferredRefreshRate,
        codec: codec ?? this.codec,
        bitDepth: bitDepth ?? this.bitDepth,
        passthroughEnabled: passthroughEnabled ?? this.passthroughEnabled,
        overrideFoveationEnable: overrideFoveationEnable ?? this.overrideFoveationEnable,
        highPowerMode: highPowerMode ?? this.highPowerMode,
        forwardKeyboard: forwardKeyboard ?? this.forwardKeyboard,
        forwardMouse: forwardMouse ?? this.forwardMouse,
        forwardGamepad: forwardGamepad ?? this.forwardGamepad,
      );
}
