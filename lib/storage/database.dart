import 'dart:ffi';
import 'dart:io';

import 'package:drift/drift.dart';
import 'package:drift/native.dart';
import 'package:path/path.dart' as path;
import 'package:path_provider/path_provider.dart';
import 'package:sqlcipher_library_windows/sqlcipher_library_windows.dart';
import 'package:sqlite3/open.dart';
import 'package:syphon/context/auth.dart';
import 'package:syphon/context/types.dart';
import 'package:syphon/global/libs/storage/key-storage.dart';
import 'package:syphon/global/print.dart';
import 'package:syphon/global/values.dart';
import 'package:syphon/storage/converters.dart';
import 'package:syphon/storage/index.dart';
// ignore: unused_import
import 'package:syphon/storage/migrations/5.update.messages.dart';
import 'package:syphon/store/auth/schema.dart';
import 'package:syphon/store/crypto/schema.dart';
import 'package:syphon/store/events/messages/model.dart';
import 'package:syphon/store/events/messages/schema.dart';
import 'package:syphon/store/events/reactions/model.dart';
import 'package:syphon/store/events/reactions/schema.dart';
import 'package:syphon/store/events/receipts/model.dart';
import 'package:syphon/store/events/receipts/schema.dart';
import 'package:syphon/store/media/encryption.dart';
import 'package:syphon/store/media/model.dart';
import 'package:syphon/store/media/schema.dart';
import 'package:syphon/store/rooms/room/model.dart';
import 'package:syphon/store/rooms/room/schema.dart';
import 'package:syphon/store/settings/schema.dart';
import 'package:syphon/store/user/model.dart';
import 'package:syphon/store/user/schema.dart';

part 'database.g.dart';

void _openOnIOS() {
  try {
    open.overrideFor(OperatingSystem.iOS, () => DynamicLibrary.process());
  } catch (error) {
    printError(error.toString());
  }
}

void _openOnAndroid() {
  try {
    open.overrideFor(OperatingSystem.android, () => DynamicLibrary.open('libsqlcipher.so'));
  } catch (error) {
    printError(error.toString());
  }
}

void _openOnLinux() {
  try {
    open.overrideFor(OperatingSystem.linux, () => DynamicLibrary.open('libsqlcipher.so'));
    return;
  } catch (_) {
    try {
      // fallback to sqlite if unavailable
      final scriptDir = File(Platform.script.toFilePath()).parent;
      final libraryNextToScript = File('${scriptDir.path}/sqlite3.so');
      final lib = DynamicLibrary.open(libraryNextToScript.path);

      open.overrideFor(OperatingSystem.linux, () => lib);
    } catch (error) {
      printError(error.toString());
      rethrow;
    }
  }
}

///
/// TODO: convert to running entirely in isolates
/// https://drift.simonbinder.eu/docs/advanced-features/isolates/
///
LazyDatabase openDatabase(AppContext context, {String pin = Values.empty}) {
  return LazyDatabase(() async {
    var storageKeyId = Storage.keyLocation;
    var storageLocation = Storage.sqliteLocation;

    final contextId = context.id;

    // prepend with context - always even if empty
    if (contextId.isNotEmpty) {
      storageKeyId = '$contextId-$storageKeyId';
      storageLocation = '$contextId-$storageLocation';
    }

    // prepend with debug mode
    storageLocation = DEBUG_MODE ? 'debug-$storageLocation' : storageLocation;

    // get application support directory for all platforms
    final dbFolder = await getApplicationSupportDirectory();
    final filePath = File(path.join(dbFolder.path, storageLocation));

    if (Platform.isWindows) {
      openSQLCipherOnWindows();
    }

    if (Platform.isIOS || Platform.isMacOS) {
      _openOnIOS();
    }

    if (Platform.isLinux) {
      _openOnLinux();
    }

    if (Platform.isAndroid) {
      _openOnAndroid();
    }

    // Configure cache encryption/decryption instance
    var storageKey = await loadKey(storageKeyId);

    final isLockedContext =
        context.id.isNotEmpty && context.secretKeyEncrypted.isNotEmpty && pin.isNotEmpty;

    // TODO: why is this completely different if I dont print here
    if (isLockedContext) {
      storageKey = await unlockSecretKey(context, pin);
    }

    return NativeDatabase(
      filePath,
      logStatements: false, // DEBUG_MODE,
      setup: (rawDb) {
        rawDb.execute("PRAGMA key = '$storageKey';");
      },
    );
  });
}

@DriftDatabase(tables: [
  Messages,
  Decrypted,
  Rooms,
  Users,
  Medias,
  Reactions,
  Receipts,
  Auths,
  Cryptos,
  Settings,
])
class StorageDatabase extends _$StorageDatabase {
  // we tell the database where to store the data with this constructor
  StorageDatabase(AppContext context, {String pin = ''}) : super(openDatabase(context, pin: pin));

  // this is the new constructor
  StorageDatabase.connect(DatabaseConnection connection) : super.connect(connection);

  // you should bump this number whenever you change or add a table definition. Migrations
  // are covered later in this readme.
  @override
  int get schemaVersion => 6;

  @override
  MigrationStrategy get migration => MigrationStrategy(
        onCreate: (Migrator m) {
          return m.createAll();
        },
        onUpgrade: (Migrator m, int from, int to) async {
          printInfo('[MIGRATION] VERSION $from to $to');
          if (from == 5) {
            await m.createTable(auths);
            await m.createTable(cryptos);
            await m.createTable(settings);
            await m.createTable(receipts);
            await m.createTable(reactions);
          }
          if (from == 4) {
            await m.addColumn(messages, messages.editIds);
            await m.addColumn(messages, messages.batch);
            await m.addColumn(messages, messages.prevBatch);
            await m.renameColumn(rooms, 'last_hash', rooms.lastBatch);
            await m.renameColumn(rooms, 'prev_hash', rooms.prevBatch);
            await m.renameColumn(rooms, 'next_hash', rooms.nextBatch);
          }
        },
      );
}
