// GENERATED CODE - DO NOT MODIFY BY HAND

part of 'database.dart';

// ignore_for_file: type=lint
class $SyncCursorsTable extends SyncCursors
    with TableInfo<$SyncCursorsTable, SyncCursorRow> {
  @override
  final GeneratedDatabase attachedDatabase;
  final String? _alias;
  $SyncCursorsTable(this.attachedDatabase, [this._alias]);
  static const VerificationMeta _stateKeyMeta = const VerificationMeta(
    'stateKey',
  );
  @override
  late final GeneratedColumn<String> stateKey = GeneratedColumn<String>(
    'state_key',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: true,
  );
  static const VerificationMeta _cursorMeta = const VerificationMeta('cursor');
  @override
  late final GeneratedColumn<String> cursor = GeneratedColumn<String>(
    'cursor',
    aliasedName,
    true,
    type: DriftSqlType.string,
    requiredDuringInsert: false,
  );
  @override
  List<GeneratedColumn> get $columns => [stateKey, cursor];
  @override
  String get aliasedName => _alias ?? actualTableName;
  @override
  String get actualTableName => $name;
  static const String $name = 'sync_cursors';
  @override
  VerificationContext validateIntegrity(
    Insertable<SyncCursorRow> instance, {
    bool isInserting = false,
  }) {
    final context = VerificationContext();
    final data = instance.toColumns(true);
    if (data.containsKey('state_key')) {
      context.handle(
        _stateKeyMeta,
        stateKey.isAcceptableOrUnknown(data['state_key']!, _stateKeyMeta),
      );
    } else if (isInserting) {
      context.missing(_stateKeyMeta);
    }
    if (data.containsKey('cursor')) {
      context.handle(
        _cursorMeta,
        cursor.isAcceptableOrUnknown(data['cursor']!, _cursorMeta),
      );
    }
    return context;
  }

  @override
  Set<GeneratedColumn> get $primaryKey => {stateKey};
  @override
  SyncCursorRow map(Map<String, dynamic> data, {String? tablePrefix}) {
    final effectivePrefix = tablePrefix != null ? '$tablePrefix.' : '';
    return SyncCursorRow(
      stateKey: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}state_key'],
      )!,
      cursor: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}cursor'],
      ),
    );
  }

  @override
  $SyncCursorsTable createAlias(String alias) {
    return $SyncCursorsTable(attachedDatabase, alias);
  }
}

class SyncCursorRow extends DataClass implements Insertable<SyncCursorRow> {
  /// 状态键（group_id 或 [workspaceStateKey]）。
  final String stateKey;

  /// 上次成功同步的服务端时间点（RFC3339）。null = 从未成功同步（下轮全量）。
  final String? cursor;
  const SyncCursorRow({required this.stateKey, this.cursor});
  @override
  Map<String, Expression> toColumns(bool nullToAbsent) {
    final map = <String, Expression>{};
    map['state_key'] = Variable<String>(stateKey);
    if (!nullToAbsent || cursor != null) {
      map['cursor'] = Variable<String>(cursor);
    }
    return map;
  }

  SyncCursorsCompanion toCompanion(bool nullToAbsent) {
    return SyncCursorsCompanion(
      stateKey: Value(stateKey),
      cursor: cursor == null && nullToAbsent
          ? const Value.absent()
          : Value(cursor),
    );
  }

  factory SyncCursorRow.fromJson(
    Map<String, dynamic> json, {
    ValueSerializer? serializer,
  }) {
    serializer ??= driftRuntimeOptions.defaultSerializer;
    return SyncCursorRow(
      stateKey: serializer.fromJson<String>(json['stateKey']),
      cursor: serializer.fromJson<String?>(json['cursor']),
    );
  }
  @override
  Map<String, dynamic> toJson({ValueSerializer? serializer}) {
    serializer ??= driftRuntimeOptions.defaultSerializer;
    return <String, dynamic>{
      'stateKey': serializer.toJson<String>(stateKey),
      'cursor': serializer.toJson<String?>(cursor),
    };
  }

  SyncCursorRow copyWith({
    String? stateKey,
    Value<String?> cursor = const Value.absent(),
  }) => SyncCursorRow(
    stateKey: stateKey ?? this.stateKey,
    cursor: cursor.present ? cursor.value : this.cursor,
  );
  SyncCursorRow copyWithCompanion(SyncCursorsCompanion data) {
    return SyncCursorRow(
      stateKey: data.stateKey.present ? data.stateKey.value : this.stateKey,
      cursor: data.cursor.present ? data.cursor.value : this.cursor,
    );
  }

  @override
  String toString() {
    return (StringBuffer('SyncCursorRow(')
          ..write('stateKey: $stateKey, ')
          ..write('cursor: $cursor')
          ..write(')'))
        .toString();
  }

  @override
  int get hashCode => Object.hash(stateKey, cursor);
  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      (other is SyncCursorRow &&
          other.stateKey == this.stateKey &&
          other.cursor == this.cursor);
}

class SyncCursorsCompanion extends UpdateCompanion<SyncCursorRow> {
  final Value<String> stateKey;
  final Value<String?> cursor;
  final Value<int> rowid;
  const SyncCursorsCompanion({
    this.stateKey = const Value.absent(),
    this.cursor = const Value.absent(),
    this.rowid = const Value.absent(),
  });
  SyncCursorsCompanion.insert({
    required String stateKey,
    this.cursor = const Value.absent(),
    this.rowid = const Value.absent(),
  }) : stateKey = Value(stateKey);
  static Insertable<SyncCursorRow> custom({
    Expression<String>? stateKey,
    Expression<String>? cursor,
    Expression<int>? rowid,
  }) {
    return RawValuesInsertable({
      if (stateKey != null) 'state_key': stateKey,
      if (cursor != null) 'cursor': cursor,
      if (rowid != null) 'rowid': rowid,
    });
  }

  SyncCursorsCompanion copyWith({
    Value<String>? stateKey,
    Value<String?>? cursor,
    Value<int>? rowid,
  }) {
    return SyncCursorsCompanion(
      stateKey: stateKey ?? this.stateKey,
      cursor: cursor ?? this.cursor,
      rowid: rowid ?? this.rowid,
    );
  }

  @override
  Map<String, Expression> toColumns(bool nullToAbsent) {
    final map = <String, Expression>{};
    if (stateKey.present) {
      map['state_key'] = Variable<String>(stateKey.value);
    }
    if (cursor.present) {
      map['cursor'] = Variable<String>(cursor.value);
    }
    if (rowid.present) {
      map['rowid'] = Variable<int>(rowid.value);
    }
    return map;
  }

  @override
  String toString() {
    return (StringBuffer('SyncCursorsCompanion(')
          ..write('stateKey: $stateKey, ')
          ..write('cursor: $cursor, ')
          ..write('rowid: $rowid')
          ..write(')'))
        .toString();
  }
}

class $SyncedFilesTable extends SyncedFiles
    with TableInfo<$SyncedFilesTable, SyncedFileRow> {
  @override
  final GeneratedDatabase attachedDatabase;
  final String? _alias;
  $SyncedFilesTable(this.attachedDatabase, [this._alias]);
  static const VerificationMeta _stateKeyMeta = const VerificationMeta(
    'stateKey',
  );
  @override
  late final GeneratedColumn<String> stateKey = GeneratedColumn<String>(
    'state_key',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: true,
  );
  static const VerificationMeta _relPathMeta = const VerificationMeta(
    'relPath',
  );
  @override
  late final GeneratedColumn<String> relPath = GeneratedColumn<String>(
    'rel_path',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: true,
  );
  static const VerificationMeta _etagMeta = const VerificationMeta('etag');
  @override
  late final GeneratedColumn<String> etag = GeneratedColumn<String>(
    'etag',
    aliasedName,
    true,
    type: DriftSqlType.string,
    requiredDuringInsert: false,
  );
  static const VerificationMeta _sizeMeta = const VerificationMeta('size');
  @override
  late final GeneratedColumn<int> size = GeneratedColumn<int>(
    'size',
    aliasedName,
    false,
    type: DriftSqlType.int,
    requiredDuringInsert: true,
  );
  static const VerificationMeta _updatedAtMeta = const VerificationMeta(
    'updatedAt',
  );
  @override
  late final GeneratedColumn<String> updatedAt = GeneratedColumn<String>(
    'updated_at',
    aliasedName,
    true,
    type: DriftSqlType.string,
    requiredDuringInsert: false,
  );
  static const VerificationMeta _contentHashMeta = const VerificationMeta(
    'contentHash',
  );
  @override
  late final GeneratedColumn<String> contentHash = GeneratedColumn<String>(
    'content_hash',
    aliasedName,
    true,
    type: DriftSqlType.string,
    requiredDuringInsert: false,
  );
  @override
  List<GeneratedColumn> get $columns => [
    stateKey,
    relPath,
    etag,
    size,
    updatedAt,
    contentHash,
  ];
  @override
  String get aliasedName => _alias ?? actualTableName;
  @override
  String get actualTableName => $name;
  static const String $name = 'synced_files';
  @override
  VerificationContext validateIntegrity(
    Insertable<SyncedFileRow> instance, {
    bool isInserting = false,
  }) {
    final context = VerificationContext();
    final data = instance.toColumns(true);
    if (data.containsKey('state_key')) {
      context.handle(
        _stateKeyMeta,
        stateKey.isAcceptableOrUnknown(data['state_key']!, _stateKeyMeta),
      );
    } else if (isInserting) {
      context.missing(_stateKeyMeta);
    }
    if (data.containsKey('rel_path')) {
      context.handle(
        _relPathMeta,
        relPath.isAcceptableOrUnknown(data['rel_path']!, _relPathMeta),
      );
    } else if (isInserting) {
      context.missing(_relPathMeta);
    }
    if (data.containsKey('etag')) {
      context.handle(
        _etagMeta,
        etag.isAcceptableOrUnknown(data['etag']!, _etagMeta),
      );
    }
    if (data.containsKey('size')) {
      context.handle(
        _sizeMeta,
        size.isAcceptableOrUnknown(data['size']!, _sizeMeta),
      );
    } else if (isInserting) {
      context.missing(_sizeMeta);
    }
    if (data.containsKey('updated_at')) {
      context.handle(
        _updatedAtMeta,
        updatedAt.isAcceptableOrUnknown(data['updated_at']!, _updatedAtMeta),
      );
    }
    if (data.containsKey('content_hash')) {
      context.handle(
        _contentHashMeta,
        contentHash.isAcceptableOrUnknown(
          data['content_hash']!,
          _contentHashMeta,
        ),
      );
    }
    return context;
  }

  @override
  Set<GeneratedColumn> get $primaryKey => {stateKey, relPath};
  @override
  SyncedFileRow map(Map<String, dynamic> data, {String? tablePrefix}) {
    final effectivePrefix = tablePrefix != null ? '$tablePrefix.' : '';
    return SyncedFileRow(
      stateKey: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}state_key'],
      )!,
      relPath: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}rel_path'],
      )!,
      etag: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}etag'],
      ),
      size: attachedDatabase.typeMapping.read(
        DriftSqlType.int,
        data['${effectivePrefix}size'],
      )!,
      updatedAt: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}updated_at'],
      ),
      contentHash: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}content_hash'],
      ),
    );
  }

  @override
  $SyncedFilesTable createAlias(String alias) {
    return $SyncedFilesTable(attachedDatabase, alias);
  }
}

class SyncedFileRow extends DataClass implements Insertable<SyncedFileRow> {
  final String stateKey;

  /// group 内相对路径（如 `grp_1/reports/a.md`）。
  final String relPath;

  /// 服务端内容指纹。null 表示服务端未返回，退化为按 [size] 比对。
  final String? etag;

  /// 同步时的字节数（etag 缺失时的兜底依据）。
  final int size;

  /// 服务端 `updated_at` 原样保留，仅用于诊断展示。
  final String? updatedAt;

  /// 下载时对实际落盘字节算的 SHA256（十六进制小写）；null = 记录写于本列
  /// 引入之前（升级前已同步），此时脏检测降级为「无法检测」（不算脏，不误报）。
  final String? contentHash;
  const SyncedFileRow({
    required this.stateKey,
    required this.relPath,
    this.etag,
    required this.size,
    this.updatedAt,
    this.contentHash,
  });
  @override
  Map<String, Expression> toColumns(bool nullToAbsent) {
    final map = <String, Expression>{};
    map['state_key'] = Variable<String>(stateKey);
    map['rel_path'] = Variable<String>(relPath);
    if (!nullToAbsent || etag != null) {
      map['etag'] = Variable<String>(etag);
    }
    map['size'] = Variable<int>(size);
    if (!nullToAbsent || updatedAt != null) {
      map['updated_at'] = Variable<String>(updatedAt);
    }
    if (!nullToAbsent || contentHash != null) {
      map['content_hash'] = Variable<String>(contentHash);
    }
    return map;
  }

  SyncedFilesCompanion toCompanion(bool nullToAbsent) {
    return SyncedFilesCompanion(
      stateKey: Value(stateKey),
      relPath: Value(relPath),
      etag: etag == null && nullToAbsent ? const Value.absent() : Value(etag),
      size: Value(size),
      updatedAt: updatedAt == null && nullToAbsent
          ? const Value.absent()
          : Value(updatedAt),
      contentHash: contentHash == null && nullToAbsent
          ? const Value.absent()
          : Value(contentHash),
    );
  }

  factory SyncedFileRow.fromJson(
    Map<String, dynamic> json, {
    ValueSerializer? serializer,
  }) {
    serializer ??= driftRuntimeOptions.defaultSerializer;
    return SyncedFileRow(
      stateKey: serializer.fromJson<String>(json['stateKey']),
      relPath: serializer.fromJson<String>(json['relPath']),
      etag: serializer.fromJson<String?>(json['etag']),
      size: serializer.fromJson<int>(json['size']),
      updatedAt: serializer.fromJson<String?>(json['updatedAt']),
      contentHash: serializer.fromJson<String?>(json['contentHash']),
    );
  }
  @override
  Map<String, dynamic> toJson({ValueSerializer? serializer}) {
    serializer ??= driftRuntimeOptions.defaultSerializer;
    return <String, dynamic>{
      'stateKey': serializer.toJson<String>(stateKey),
      'relPath': serializer.toJson<String>(relPath),
      'etag': serializer.toJson<String?>(etag),
      'size': serializer.toJson<int>(size),
      'updatedAt': serializer.toJson<String?>(updatedAt),
      'contentHash': serializer.toJson<String?>(contentHash),
    };
  }

  SyncedFileRow copyWith({
    String? stateKey,
    String? relPath,
    Value<String?> etag = const Value.absent(),
    int? size,
    Value<String?> updatedAt = const Value.absent(),
    Value<String?> contentHash = const Value.absent(),
  }) => SyncedFileRow(
    stateKey: stateKey ?? this.stateKey,
    relPath: relPath ?? this.relPath,
    etag: etag.present ? etag.value : this.etag,
    size: size ?? this.size,
    updatedAt: updatedAt.present ? updatedAt.value : this.updatedAt,
    contentHash: contentHash.present ? contentHash.value : this.contentHash,
  );
  SyncedFileRow copyWithCompanion(SyncedFilesCompanion data) {
    return SyncedFileRow(
      stateKey: data.stateKey.present ? data.stateKey.value : this.stateKey,
      relPath: data.relPath.present ? data.relPath.value : this.relPath,
      etag: data.etag.present ? data.etag.value : this.etag,
      size: data.size.present ? data.size.value : this.size,
      updatedAt: data.updatedAt.present ? data.updatedAt.value : this.updatedAt,
      contentHash: data.contentHash.present
          ? data.contentHash.value
          : this.contentHash,
    );
  }

  @override
  String toString() {
    return (StringBuffer('SyncedFileRow(')
          ..write('stateKey: $stateKey, ')
          ..write('relPath: $relPath, ')
          ..write('etag: $etag, ')
          ..write('size: $size, ')
          ..write('updatedAt: $updatedAt, ')
          ..write('contentHash: $contentHash')
          ..write(')'))
        .toString();
  }

  @override
  int get hashCode =>
      Object.hash(stateKey, relPath, etag, size, updatedAt, contentHash);
  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      (other is SyncedFileRow &&
          other.stateKey == this.stateKey &&
          other.relPath == this.relPath &&
          other.etag == this.etag &&
          other.size == this.size &&
          other.updatedAt == this.updatedAt &&
          other.contentHash == this.contentHash);
}

class SyncedFilesCompanion extends UpdateCompanion<SyncedFileRow> {
  final Value<String> stateKey;
  final Value<String> relPath;
  final Value<String?> etag;
  final Value<int> size;
  final Value<String?> updatedAt;
  final Value<String?> contentHash;
  final Value<int> rowid;
  const SyncedFilesCompanion({
    this.stateKey = const Value.absent(),
    this.relPath = const Value.absent(),
    this.etag = const Value.absent(),
    this.size = const Value.absent(),
    this.updatedAt = const Value.absent(),
    this.contentHash = const Value.absent(),
    this.rowid = const Value.absent(),
  });
  SyncedFilesCompanion.insert({
    required String stateKey,
    required String relPath,
    this.etag = const Value.absent(),
    required int size,
    this.updatedAt = const Value.absent(),
    this.contentHash = const Value.absent(),
    this.rowid = const Value.absent(),
  }) : stateKey = Value(stateKey),
       relPath = Value(relPath),
       size = Value(size);
  static Insertable<SyncedFileRow> custom({
    Expression<String>? stateKey,
    Expression<String>? relPath,
    Expression<String>? etag,
    Expression<int>? size,
    Expression<String>? updatedAt,
    Expression<String>? contentHash,
    Expression<int>? rowid,
  }) {
    return RawValuesInsertable({
      if (stateKey != null) 'state_key': stateKey,
      if (relPath != null) 'rel_path': relPath,
      if (etag != null) 'etag': etag,
      if (size != null) 'size': size,
      if (updatedAt != null) 'updated_at': updatedAt,
      if (contentHash != null) 'content_hash': contentHash,
      if (rowid != null) 'rowid': rowid,
    });
  }

  SyncedFilesCompanion copyWith({
    Value<String>? stateKey,
    Value<String>? relPath,
    Value<String?>? etag,
    Value<int>? size,
    Value<String?>? updatedAt,
    Value<String?>? contentHash,
    Value<int>? rowid,
  }) {
    return SyncedFilesCompanion(
      stateKey: stateKey ?? this.stateKey,
      relPath: relPath ?? this.relPath,
      etag: etag ?? this.etag,
      size: size ?? this.size,
      updatedAt: updatedAt ?? this.updatedAt,
      contentHash: contentHash ?? this.contentHash,
      rowid: rowid ?? this.rowid,
    );
  }

  @override
  Map<String, Expression> toColumns(bool nullToAbsent) {
    final map = <String, Expression>{};
    if (stateKey.present) {
      map['state_key'] = Variable<String>(stateKey.value);
    }
    if (relPath.present) {
      map['rel_path'] = Variable<String>(relPath.value);
    }
    if (etag.present) {
      map['etag'] = Variable<String>(etag.value);
    }
    if (size.present) {
      map['size'] = Variable<int>(size.value);
    }
    if (updatedAt.present) {
      map['updated_at'] = Variable<String>(updatedAt.value);
    }
    if (contentHash.present) {
      map['content_hash'] = Variable<String>(contentHash.value);
    }
    if (rowid.present) {
      map['rowid'] = Variable<int>(rowid.value);
    }
    return map;
  }

  @override
  String toString() {
    return (StringBuffer('SyncedFilesCompanion(')
          ..write('stateKey: $stateKey, ')
          ..write('relPath: $relPath, ')
          ..write('etag: $etag, ')
          ..write('size: $size, ')
          ..write('updatedAt: $updatedAt, ')
          ..write('contentHash: $contentHash, ')
          ..write('rowid: $rowid')
          ..write(')'))
        .toString();
  }
}

class $SyncBindingsTable extends SyncBindings
    with TableInfo<$SyncBindingsTable, SyncBindingRow> {
  @override
  final GeneratedDatabase attachedDatabase;
  final String? _alias;
  $SyncBindingsTable(this.attachedDatabase, [this._alias]);
  static const VerificationMeta _idMeta = const VerificationMeta('id');
  @override
  late final GeneratedColumn<int> id = GeneratedColumn<int>(
    'id',
    aliasedName,
    false,
    type: DriftSqlType.int,
    requiredDuringInsert: false,
  );
  static const VerificationMeta _localRootMeta = const VerificationMeta(
    'localRoot',
  );
  @override
  late final GeneratedColumn<String> localRoot = GeneratedColumn<String>(
    'local_root',
    aliasedName,
    true,
    type: DriftSqlType.string,
    requiredDuringInsert: false,
  );
  @override
  List<GeneratedColumn> get $columns => [id, localRoot];
  @override
  String get aliasedName => _alias ?? actualTableName;
  @override
  String get actualTableName => $name;
  static const String $name = 'sync_bindings';
  @override
  VerificationContext validateIntegrity(
    Insertable<SyncBindingRow> instance, {
    bool isInserting = false,
  }) {
    final context = VerificationContext();
    final data = instance.toColumns(true);
    if (data.containsKey('id')) {
      context.handle(_idMeta, id.isAcceptableOrUnknown(data['id']!, _idMeta));
    }
    if (data.containsKey('local_root')) {
      context.handle(
        _localRootMeta,
        localRoot.isAcceptableOrUnknown(data['local_root']!, _localRootMeta),
      );
    }
    return context;
  }

  @override
  Set<GeneratedColumn> get $primaryKey => {id};
  @override
  SyncBindingRow map(Map<String, dynamic> data, {String? tablePrefix}) {
    final effectivePrefix = tablePrefix != null ? '$tablePrefix.' : '';
    return SyncBindingRow(
      id: attachedDatabase.typeMapping.read(
        DriftSqlType.int,
        data['${effectivePrefix}id'],
      )!,
      localRoot: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}local_root'],
      ),
    );
  }

  @override
  $SyncBindingsTable createAlias(String alias) {
    return $SyncBindingsTable(attachedDatabase, alias);
  }
}

class SyncBindingRow extends DataClass implements Insertable<SyncBindingRow> {
  final int id;

  /// 当前绑定的同步目录绝对路径。null = 尚未选过目录。
  final String? localRoot;
  const SyncBindingRow({required this.id, this.localRoot});
  @override
  Map<String, Expression> toColumns(bool nullToAbsent) {
    final map = <String, Expression>{};
    map['id'] = Variable<int>(id);
    if (!nullToAbsent || localRoot != null) {
      map['local_root'] = Variable<String>(localRoot);
    }
    return map;
  }

  SyncBindingsCompanion toCompanion(bool nullToAbsent) {
    return SyncBindingsCompanion(
      id: Value(id),
      localRoot: localRoot == null && nullToAbsent
          ? const Value.absent()
          : Value(localRoot),
    );
  }

  factory SyncBindingRow.fromJson(
    Map<String, dynamic> json, {
    ValueSerializer? serializer,
  }) {
    serializer ??= driftRuntimeOptions.defaultSerializer;
    return SyncBindingRow(
      id: serializer.fromJson<int>(json['id']),
      localRoot: serializer.fromJson<String?>(json['localRoot']),
    );
  }
  @override
  Map<String, dynamic> toJson({ValueSerializer? serializer}) {
    serializer ??= driftRuntimeOptions.defaultSerializer;
    return <String, dynamic>{
      'id': serializer.toJson<int>(id),
      'localRoot': serializer.toJson<String?>(localRoot),
    };
  }

  SyncBindingRow copyWith({
    int? id,
    Value<String?> localRoot = const Value.absent(),
  }) => SyncBindingRow(
    id: id ?? this.id,
    localRoot: localRoot.present ? localRoot.value : this.localRoot,
  );
  SyncBindingRow copyWithCompanion(SyncBindingsCompanion data) {
    return SyncBindingRow(
      id: data.id.present ? data.id.value : this.id,
      localRoot: data.localRoot.present ? data.localRoot.value : this.localRoot,
    );
  }

  @override
  String toString() {
    return (StringBuffer('SyncBindingRow(')
          ..write('id: $id, ')
          ..write('localRoot: $localRoot')
          ..write(')'))
        .toString();
  }

  @override
  int get hashCode => Object.hash(id, localRoot);
  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      (other is SyncBindingRow &&
          other.id == this.id &&
          other.localRoot == this.localRoot);
}

class SyncBindingsCompanion extends UpdateCompanion<SyncBindingRow> {
  final Value<int> id;
  final Value<String?> localRoot;
  const SyncBindingsCompanion({
    this.id = const Value.absent(),
    this.localRoot = const Value.absent(),
  });
  SyncBindingsCompanion.insert({
    this.id = const Value.absent(),
    this.localRoot = const Value.absent(),
  });
  static Insertable<SyncBindingRow> custom({
    Expression<int>? id,
    Expression<String>? localRoot,
  }) {
    return RawValuesInsertable({
      if (id != null) 'id': id,
      if (localRoot != null) 'local_root': localRoot,
    });
  }

  SyncBindingsCompanion copyWith({Value<int>? id, Value<String?>? localRoot}) {
    return SyncBindingsCompanion(
      id: id ?? this.id,
      localRoot: localRoot ?? this.localRoot,
    );
  }

  @override
  Map<String, Expression> toColumns(bool nullToAbsent) {
    final map = <String, Expression>{};
    if (id.present) {
      map['id'] = Variable<int>(id.value);
    }
    if (localRoot.present) {
      map['local_root'] = Variable<String>(localRoot.value);
    }
    return map;
  }

  @override
  String toString() {
    return (StringBuffer('SyncBindingsCompanion(')
          ..write('id: $id, ')
          ..write('localRoot: $localRoot')
          ..write(')'))
        .toString();
  }
}

class $CachedGroupsTable extends CachedGroups
    with TableInfo<$CachedGroupsTable, CachedGroupRow> {
  @override
  final GeneratedDatabase attachedDatabase;
  final String? _alias;
  $CachedGroupsTable(this.attachedDatabase, [this._alias]);
  static const VerificationMeta _idMeta = const VerificationMeta('id');
  @override
  late final GeneratedColumn<String> id = GeneratedColumn<String>(
    'id',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: true,
  );
  static const VerificationMeta _userIdMeta = const VerificationMeta('userId');
  @override
  late final GeneratedColumn<String> userId = GeneratedColumn<String>(
    'user_id',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: true,
  );
  static const VerificationMeta _payloadMeta = const VerificationMeta(
    'payload',
  );
  @override
  late final GeneratedColumn<String> payload = GeneratedColumn<String>(
    'payload',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: true,
  );
  static const VerificationMeta _updatedAtMeta = const VerificationMeta(
    'updatedAt',
  );
  @override
  late final GeneratedColumn<String> updatedAt = GeneratedColumn<String>(
    'updated_at',
    aliasedName,
    true,
    type: DriftSqlType.string,
    requiredDuringInsert: false,
  );
  static const VerificationMeta _fetchedAtMeta = const VerificationMeta(
    'fetchedAt',
  );
  @override
  late final GeneratedColumn<int> fetchedAt = GeneratedColumn<int>(
    'fetched_at',
    aliasedName,
    false,
    type: DriftSqlType.int,
    requiredDuringInsert: true,
  );
  @override
  List<GeneratedColumn> get $columns => [
    id,
    userId,
    payload,
    updatedAt,
    fetchedAt,
  ];
  @override
  String get aliasedName => _alias ?? actualTableName;
  @override
  String get actualTableName => $name;
  static const String $name = 'cached_groups';
  @override
  VerificationContext validateIntegrity(
    Insertable<CachedGroupRow> instance, {
    bool isInserting = false,
  }) {
    final context = VerificationContext();
    final data = instance.toColumns(true);
    if (data.containsKey('id')) {
      context.handle(_idMeta, id.isAcceptableOrUnknown(data['id']!, _idMeta));
    } else if (isInserting) {
      context.missing(_idMeta);
    }
    if (data.containsKey('user_id')) {
      context.handle(
        _userIdMeta,
        userId.isAcceptableOrUnknown(data['user_id']!, _userIdMeta),
      );
    } else if (isInserting) {
      context.missing(_userIdMeta);
    }
    if (data.containsKey('payload')) {
      context.handle(
        _payloadMeta,
        payload.isAcceptableOrUnknown(data['payload']!, _payloadMeta),
      );
    } else if (isInserting) {
      context.missing(_payloadMeta);
    }
    if (data.containsKey('updated_at')) {
      context.handle(
        _updatedAtMeta,
        updatedAt.isAcceptableOrUnknown(data['updated_at']!, _updatedAtMeta),
      );
    }
    if (data.containsKey('fetched_at')) {
      context.handle(
        _fetchedAtMeta,
        fetchedAt.isAcceptableOrUnknown(data['fetched_at']!, _fetchedAtMeta),
      );
    } else if (isInserting) {
      context.missing(_fetchedAtMeta);
    }
    return context;
  }

  @override
  Set<GeneratedColumn> get $primaryKey => {id};
  @override
  CachedGroupRow map(Map<String, dynamic> data, {String? tablePrefix}) {
    final effectivePrefix = tablePrefix != null ? '$tablePrefix.' : '';
    return CachedGroupRow(
      id: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}id'],
      )!,
      userId: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}user_id'],
      )!,
      payload: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}payload'],
      )!,
      updatedAt: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}updated_at'],
      ),
      fetchedAt: attachedDatabase.typeMapping.read(
        DriftSqlType.int,
        data['${effectivePrefix}fetched_at'],
      )!,
    );
  }

  @override
  $CachedGroupsTable createAlias(String alias) {
    return $CachedGroupsTable(attachedDatabase, alias);
  }
}

class CachedGroupRow extends DataClass implements Insertable<CachedGroupRow> {
  /// group id（服务端主键）。
  final String id;

  /// 归属用户。
  ///
  /// ## 为什么必须有这一列（不能只靠「切换账号时清库」）
  ///
  /// `ChatApi.listGroups` 走的是网关注入的 `X-User-ID`，同一台机器换账号后
  /// 缓存会串——A 账号会看到 B 账号的对话列表。而「登出时清缓存」会漏：登出
  /// 路径不止一条（token 过期、手动清凭证、进程被杀后重登），任一条没清就串了。
  /// 把 user_id 放进主键的查询条件里，串号在结构上不可能发生。
  final String userId;

  /// 服务端返回的 group JSON **原文**（`ChatGroup.fromJson` 的输入）。
  final String payload;

  /// 服务端 `updated_at` 原样保留，仅用于诊断。
  final String? updatedAt;

  /// 本地写入时刻（毫秒 epoch）。
  ///
  /// 用于「离线数据 · X 前更新」提示（`docs/offline-cache-design.md` §3.4）。
  /// ⚠️ **不是 TTL 依据**：本设计明确不用 TTL——TTL 会在长时间断网（最需要
  /// 缓存的时刻）主动清掉缓存，把用户打回白屏。
  final int fetchedAt;
  const CachedGroupRow({
    required this.id,
    required this.userId,
    required this.payload,
    this.updatedAt,
    required this.fetchedAt,
  });
  @override
  Map<String, Expression> toColumns(bool nullToAbsent) {
    final map = <String, Expression>{};
    map['id'] = Variable<String>(id);
    map['user_id'] = Variable<String>(userId);
    map['payload'] = Variable<String>(payload);
    if (!nullToAbsent || updatedAt != null) {
      map['updated_at'] = Variable<String>(updatedAt);
    }
    map['fetched_at'] = Variable<int>(fetchedAt);
    return map;
  }

  CachedGroupsCompanion toCompanion(bool nullToAbsent) {
    return CachedGroupsCompanion(
      id: Value(id),
      userId: Value(userId),
      payload: Value(payload),
      updatedAt: updatedAt == null && nullToAbsent
          ? const Value.absent()
          : Value(updatedAt),
      fetchedAt: Value(fetchedAt),
    );
  }

  factory CachedGroupRow.fromJson(
    Map<String, dynamic> json, {
    ValueSerializer? serializer,
  }) {
    serializer ??= driftRuntimeOptions.defaultSerializer;
    return CachedGroupRow(
      id: serializer.fromJson<String>(json['id']),
      userId: serializer.fromJson<String>(json['userId']),
      payload: serializer.fromJson<String>(json['payload']),
      updatedAt: serializer.fromJson<String?>(json['updatedAt']),
      fetchedAt: serializer.fromJson<int>(json['fetchedAt']),
    );
  }
  @override
  Map<String, dynamic> toJson({ValueSerializer? serializer}) {
    serializer ??= driftRuntimeOptions.defaultSerializer;
    return <String, dynamic>{
      'id': serializer.toJson<String>(id),
      'userId': serializer.toJson<String>(userId),
      'payload': serializer.toJson<String>(payload),
      'updatedAt': serializer.toJson<String?>(updatedAt),
      'fetchedAt': serializer.toJson<int>(fetchedAt),
    };
  }

  CachedGroupRow copyWith({
    String? id,
    String? userId,
    String? payload,
    Value<String?> updatedAt = const Value.absent(),
    int? fetchedAt,
  }) => CachedGroupRow(
    id: id ?? this.id,
    userId: userId ?? this.userId,
    payload: payload ?? this.payload,
    updatedAt: updatedAt.present ? updatedAt.value : this.updatedAt,
    fetchedAt: fetchedAt ?? this.fetchedAt,
  );
  CachedGroupRow copyWithCompanion(CachedGroupsCompanion data) {
    return CachedGroupRow(
      id: data.id.present ? data.id.value : this.id,
      userId: data.userId.present ? data.userId.value : this.userId,
      payload: data.payload.present ? data.payload.value : this.payload,
      updatedAt: data.updatedAt.present ? data.updatedAt.value : this.updatedAt,
      fetchedAt: data.fetchedAt.present ? data.fetchedAt.value : this.fetchedAt,
    );
  }

  @override
  String toString() {
    return (StringBuffer('CachedGroupRow(')
          ..write('id: $id, ')
          ..write('userId: $userId, ')
          ..write('payload: $payload, ')
          ..write('updatedAt: $updatedAt, ')
          ..write('fetchedAt: $fetchedAt')
          ..write(')'))
        .toString();
  }

  @override
  int get hashCode => Object.hash(id, userId, payload, updatedAt, fetchedAt);
  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      (other is CachedGroupRow &&
          other.id == this.id &&
          other.userId == this.userId &&
          other.payload == this.payload &&
          other.updatedAt == this.updatedAt &&
          other.fetchedAt == this.fetchedAt);
}

class CachedGroupsCompanion extends UpdateCompanion<CachedGroupRow> {
  final Value<String> id;
  final Value<String> userId;
  final Value<String> payload;
  final Value<String?> updatedAt;
  final Value<int> fetchedAt;
  final Value<int> rowid;
  const CachedGroupsCompanion({
    this.id = const Value.absent(),
    this.userId = const Value.absent(),
    this.payload = const Value.absent(),
    this.updatedAt = const Value.absent(),
    this.fetchedAt = const Value.absent(),
    this.rowid = const Value.absent(),
  });
  CachedGroupsCompanion.insert({
    required String id,
    required String userId,
    required String payload,
    this.updatedAt = const Value.absent(),
    required int fetchedAt,
    this.rowid = const Value.absent(),
  }) : id = Value(id),
       userId = Value(userId),
       payload = Value(payload),
       fetchedAt = Value(fetchedAt);
  static Insertable<CachedGroupRow> custom({
    Expression<String>? id,
    Expression<String>? userId,
    Expression<String>? payload,
    Expression<String>? updatedAt,
    Expression<int>? fetchedAt,
    Expression<int>? rowid,
  }) {
    return RawValuesInsertable({
      if (id != null) 'id': id,
      if (userId != null) 'user_id': userId,
      if (payload != null) 'payload': payload,
      if (updatedAt != null) 'updated_at': updatedAt,
      if (fetchedAt != null) 'fetched_at': fetchedAt,
      if (rowid != null) 'rowid': rowid,
    });
  }

  CachedGroupsCompanion copyWith({
    Value<String>? id,
    Value<String>? userId,
    Value<String>? payload,
    Value<String?>? updatedAt,
    Value<int>? fetchedAt,
    Value<int>? rowid,
  }) {
    return CachedGroupsCompanion(
      id: id ?? this.id,
      userId: userId ?? this.userId,
      payload: payload ?? this.payload,
      updatedAt: updatedAt ?? this.updatedAt,
      fetchedAt: fetchedAt ?? this.fetchedAt,
      rowid: rowid ?? this.rowid,
    );
  }

  @override
  Map<String, Expression> toColumns(bool nullToAbsent) {
    final map = <String, Expression>{};
    if (id.present) {
      map['id'] = Variable<String>(id.value);
    }
    if (userId.present) {
      map['user_id'] = Variable<String>(userId.value);
    }
    if (payload.present) {
      map['payload'] = Variable<String>(payload.value);
    }
    if (updatedAt.present) {
      map['updated_at'] = Variable<String>(updatedAt.value);
    }
    if (fetchedAt.present) {
      map['fetched_at'] = Variable<int>(fetchedAt.value);
    }
    if (rowid.present) {
      map['rowid'] = Variable<int>(rowid.value);
    }
    return map;
  }

  @override
  String toString() {
    return (StringBuffer('CachedGroupsCompanion(')
          ..write('id: $id, ')
          ..write('userId: $userId, ')
          ..write('payload: $payload, ')
          ..write('updatedAt: $updatedAt, ')
          ..write('fetchedAt: $fetchedAt, ')
          ..write('rowid: $rowid')
          ..write(')'))
        .toString();
  }
}

class $CachedEventsTable extends CachedEvents
    with TableInfo<$CachedEventsTable, CachedEventRow> {
  @override
  final GeneratedDatabase attachedDatabase;
  final String? _alias;
  $CachedEventsTable(this.attachedDatabase, [this._alias]);
  static const VerificationMeta _groupIdMeta = const VerificationMeta(
    'groupId',
  );
  @override
  late final GeneratedColumn<String> groupId = GeneratedColumn<String>(
    'group_id',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: true,
  );
  static const VerificationMeta _globalSeqMeta = const VerificationMeta(
    'globalSeq',
  );
  @override
  late final GeneratedColumn<int> globalSeq = GeneratedColumn<int>(
    'global_seq',
    aliasedName,
    false,
    type: DriftSqlType.int,
    requiredDuringInsert: true,
  );
  static const VerificationMeta _payloadMeta = const VerificationMeta(
    'payload',
  );
  @override
  late final GeneratedColumn<String> payload = GeneratedColumn<String>(
    'payload',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: true,
  );
  static const VerificationMeta _cachedAtMeta = const VerificationMeta(
    'cachedAt',
  );
  @override
  late final GeneratedColumn<int> cachedAt = GeneratedColumn<int>(
    'cached_at',
    aliasedName,
    false,
    type: DriftSqlType.int,
    requiredDuringInsert: true,
  );
  static const VerificationMeta _lastAccessedAtMeta = const VerificationMeta(
    'lastAccessedAt',
  );
  @override
  late final GeneratedColumn<int> lastAccessedAt = GeneratedColumn<int>(
    'last_accessed_at',
    aliasedName,
    false,
    type: DriftSqlType.int,
    requiredDuringInsert: true,
  );
  @override
  List<GeneratedColumn> get $columns => [
    groupId,
    globalSeq,
    payload,
    cachedAt,
    lastAccessedAt,
  ];
  @override
  String get aliasedName => _alias ?? actualTableName;
  @override
  String get actualTableName => $name;
  static const String $name = 'cached_events';
  @override
  VerificationContext validateIntegrity(
    Insertable<CachedEventRow> instance, {
    bool isInserting = false,
  }) {
    final context = VerificationContext();
    final data = instance.toColumns(true);
    if (data.containsKey('group_id')) {
      context.handle(
        _groupIdMeta,
        groupId.isAcceptableOrUnknown(data['group_id']!, _groupIdMeta),
      );
    } else if (isInserting) {
      context.missing(_groupIdMeta);
    }
    if (data.containsKey('global_seq')) {
      context.handle(
        _globalSeqMeta,
        globalSeq.isAcceptableOrUnknown(data['global_seq']!, _globalSeqMeta),
      );
    } else if (isInserting) {
      context.missing(_globalSeqMeta);
    }
    if (data.containsKey('payload')) {
      context.handle(
        _payloadMeta,
        payload.isAcceptableOrUnknown(data['payload']!, _payloadMeta),
      );
    } else if (isInserting) {
      context.missing(_payloadMeta);
    }
    if (data.containsKey('cached_at')) {
      context.handle(
        _cachedAtMeta,
        cachedAt.isAcceptableOrUnknown(data['cached_at']!, _cachedAtMeta),
      );
    } else if (isInserting) {
      context.missing(_cachedAtMeta);
    }
    if (data.containsKey('last_accessed_at')) {
      context.handle(
        _lastAccessedAtMeta,
        lastAccessedAt.isAcceptableOrUnknown(
          data['last_accessed_at']!,
          _lastAccessedAtMeta,
        ),
      );
    } else if (isInserting) {
      context.missing(_lastAccessedAtMeta);
    }
    return context;
  }

  @override
  Set<GeneratedColumn> get $primaryKey => {groupId, globalSeq};
  @override
  CachedEventRow map(Map<String, dynamic> data, {String? tablePrefix}) {
    final effectivePrefix = tablePrefix != null ? '$tablePrefix.' : '';
    return CachedEventRow(
      groupId: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}group_id'],
      )!,
      globalSeq: attachedDatabase.typeMapping.read(
        DriftSqlType.int,
        data['${effectivePrefix}global_seq'],
      )!,
      payload: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}payload'],
      )!,
      cachedAt: attachedDatabase.typeMapping.read(
        DriftSqlType.int,
        data['${effectivePrefix}cached_at'],
      )!,
      lastAccessedAt: attachedDatabase.typeMapping.read(
        DriftSqlType.int,
        data['${effectivePrefix}last_accessed_at'],
      )!,
    );
  }

  @override
  $CachedEventsTable createAlias(String alias) {
    return $CachedEventsTable(attachedDatabase, alias);
  }
}

class CachedEventRow extends DataClass implements Insertable<CachedEventRow> {
  /// 归属 group。
  final String groupId;

  /// 落库事件的全局序（**不是** per-turn 的 `seq`）。
  final int globalSeq;

  /// `ChatEvent.toJson()` 原文。
  final String payload;

  /// 本地写入时刻（毫秒 epoch）。
  final int cachedAt;

  /// 最近一次被读取的时刻（毫秒 epoch），全库超限时按它**整 group** 淘汰。
  ///
  /// ## 为什么在 group 级而不是事件级
  ///
  /// 按事件淘汰会让某 group 的历史出现「中间空洞」：用户向上翻页时看到
  /// `globalSeq` 跳跃，且无法判断是「被淘汰了」还是「服务端就没有」。整 group
  /// 淘汰的语义是清晰的：**这个 group 没有缓存**（`docs/offline-cache-design.md` §5.3）。
  final int lastAccessedAt;
  const CachedEventRow({
    required this.groupId,
    required this.globalSeq,
    required this.payload,
    required this.cachedAt,
    required this.lastAccessedAt,
  });
  @override
  Map<String, Expression> toColumns(bool nullToAbsent) {
    final map = <String, Expression>{};
    map['group_id'] = Variable<String>(groupId);
    map['global_seq'] = Variable<int>(globalSeq);
    map['payload'] = Variable<String>(payload);
    map['cached_at'] = Variable<int>(cachedAt);
    map['last_accessed_at'] = Variable<int>(lastAccessedAt);
    return map;
  }

  CachedEventsCompanion toCompanion(bool nullToAbsent) {
    return CachedEventsCompanion(
      groupId: Value(groupId),
      globalSeq: Value(globalSeq),
      payload: Value(payload),
      cachedAt: Value(cachedAt),
      lastAccessedAt: Value(lastAccessedAt),
    );
  }

  factory CachedEventRow.fromJson(
    Map<String, dynamic> json, {
    ValueSerializer? serializer,
  }) {
    serializer ??= driftRuntimeOptions.defaultSerializer;
    return CachedEventRow(
      groupId: serializer.fromJson<String>(json['groupId']),
      globalSeq: serializer.fromJson<int>(json['globalSeq']),
      payload: serializer.fromJson<String>(json['payload']),
      cachedAt: serializer.fromJson<int>(json['cachedAt']),
      lastAccessedAt: serializer.fromJson<int>(json['lastAccessedAt']),
    );
  }
  @override
  Map<String, dynamic> toJson({ValueSerializer? serializer}) {
    serializer ??= driftRuntimeOptions.defaultSerializer;
    return <String, dynamic>{
      'groupId': serializer.toJson<String>(groupId),
      'globalSeq': serializer.toJson<int>(globalSeq),
      'payload': serializer.toJson<String>(payload),
      'cachedAt': serializer.toJson<int>(cachedAt),
      'lastAccessedAt': serializer.toJson<int>(lastAccessedAt),
    };
  }

  CachedEventRow copyWith({
    String? groupId,
    int? globalSeq,
    String? payload,
    int? cachedAt,
    int? lastAccessedAt,
  }) => CachedEventRow(
    groupId: groupId ?? this.groupId,
    globalSeq: globalSeq ?? this.globalSeq,
    payload: payload ?? this.payload,
    cachedAt: cachedAt ?? this.cachedAt,
    lastAccessedAt: lastAccessedAt ?? this.lastAccessedAt,
  );
  CachedEventRow copyWithCompanion(CachedEventsCompanion data) {
    return CachedEventRow(
      groupId: data.groupId.present ? data.groupId.value : this.groupId,
      globalSeq: data.globalSeq.present ? data.globalSeq.value : this.globalSeq,
      payload: data.payload.present ? data.payload.value : this.payload,
      cachedAt: data.cachedAt.present ? data.cachedAt.value : this.cachedAt,
      lastAccessedAt: data.lastAccessedAt.present
          ? data.lastAccessedAt.value
          : this.lastAccessedAt,
    );
  }

  @override
  String toString() {
    return (StringBuffer('CachedEventRow(')
          ..write('groupId: $groupId, ')
          ..write('globalSeq: $globalSeq, ')
          ..write('payload: $payload, ')
          ..write('cachedAt: $cachedAt, ')
          ..write('lastAccessedAt: $lastAccessedAt')
          ..write(')'))
        .toString();
  }

  @override
  int get hashCode =>
      Object.hash(groupId, globalSeq, payload, cachedAt, lastAccessedAt);
  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      (other is CachedEventRow &&
          other.groupId == this.groupId &&
          other.globalSeq == this.globalSeq &&
          other.payload == this.payload &&
          other.cachedAt == this.cachedAt &&
          other.lastAccessedAt == this.lastAccessedAt);
}

class CachedEventsCompanion extends UpdateCompanion<CachedEventRow> {
  final Value<String> groupId;
  final Value<int> globalSeq;
  final Value<String> payload;
  final Value<int> cachedAt;
  final Value<int> lastAccessedAt;
  final Value<int> rowid;
  const CachedEventsCompanion({
    this.groupId = const Value.absent(),
    this.globalSeq = const Value.absent(),
    this.payload = const Value.absent(),
    this.cachedAt = const Value.absent(),
    this.lastAccessedAt = const Value.absent(),
    this.rowid = const Value.absent(),
  });
  CachedEventsCompanion.insert({
    required String groupId,
    required int globalSeq,
    required String payload,
    required int cachedAt,
    required int lastAccessedAt,
    this.rowid = const Value.absent(),
  }) : groupId = Value(groupId),
       globalSeq = Value(globalSeq),
       payload = Value(payload),
       cachedAt = Value(cachedAt),
       lastAccessedAt = Value(lastAccessedAt);
  static Insertable<CachedEventRow> custom({
    Expression<String>? groupId,
    Expression<int>? globalSeq,
    Expression<String>? payload,
    Expression<int>? cachedAt,
    Expression<int>? lastAccessedAt,
    Expression<int>? rowid,
  }) {
    return RawValuesInsertable({
      if (groupId != null) 'group_id': groupId,
      if (globalSeq != null) 'global_seq': globalSeq,
      if (payload != null) 'payload': payload,
      if (cachedAt != null) 'cached_at': cachedAt,
      if (lastAccessedAt != null) 'last_accessed_at': lastAccessedAt,
      if (rowid != null) 'rowid': rowid,
    });
  }

  CachedEventsCompanion copyWith({
    Value<String>? groupId,
    Value<int>? globalSeq,
    Value<String>? payload,
    Value<int>? cachedAt,
    Value<int>? lastAccessedAt,
    Value<int>? rowid,
  }) {
    return CachedEventsCompanion(
      groupId: groupId ?? this.groupId,
      globalSeq: globalSeq ?? this.globalSeq,
      payload: payload ?? this.payload,
      cachedAt: cachedAt ?? this.cachedAt,
      lastAccessedAt: lastAccessedAt ?? this.lastAccessedAt,
      rowid: rowid ?? this.rowid,
    );
  }

  @override
  Map<String, Expression> toColumns(bool nullToAbsent) {
    final map = <String, Expression>{};
    if (groupId.present) {
      map['group_id'] = Variable<String>(groupId.value);
    }
    if (globalSeq.present) {
      map['global_seq'] = Variable<int>(globalSeq.value);
    }
    if (payload.present) {
      map['payload'] = Variable<String>(payload.value);
    }
    if (cachedAt.present) {
      map['cached_at'] = Variable<int>(cachedAt.value);
    }
    if (lastAccessedAt.present) {
      map['last_accessed_at'] = Variable<int>(lastAccessedAt.value);
    }
    if (rowid.present) {
      map['rowid'] = Variable<int>(rowid.value);
    }
    return map;
  }

  @override
  String toString() {
    return (StringBuffer('CachedEventsCompanion(')
          ..write('groupId: $groupId, ')
          ..write('globalSeq: $globalSeq, ')
          ..write('payload: $payload, ')
          ..write('cachedAt: $cachedAt, ')
          ..write('lastAccessedAt: $lastAccessedAt, ')
          ..write('rowid: $rowid')
          ..write(')'))
        .toString();
  }
}

class $OutboxEntriesTable extends OutboxEntries
    with TableInfo<$OutboxEntriesTable, OutboxRow> {
  @override
  final GeneratedDatabase attachedDatabase;
  final String? _alias;
  $OutboxEntriesTable(this.attachedDatabase, [this._alias]);
  static const VerificationMeta _idMeta = const VerificationMeta('id');
  @override
  late final GeneratedColumn<String> id = GeneratedColumn<String>(
    'id',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: true,
  );
  static const VerificationMeta _userIdMeta = const VerificationMeta('userId');
  @override
  late final GeneratedColumn<String> userId = GeneratedColumn<String>(
    'user_id',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: true,
  );
  static const VerificationMeta _groupIdMeta = const VerificationMeta(
    'groupId',
  );
  @override
  late final GeneratedColumn<String> groupId = GeneratedColumn<String>(
    'group_id',
    aliasedName,
    true,
    type: DriftSqlType.string,
    requiredDuringInsert: false,
  );
  static const VerificationMeta _agentIdMeta = const VerificationMeta(
    'agentId',
  );
  @override
  late final GeneratedColumn<String> agentId = GeneratedColumn<String>(
    'agent_id',
    aliasedName,
    true,
    type: DriftSqlType.string,
    requiredDuringInsert: false,
  );
  static const VerificationMeta _inputMeta = const VerificationMeta('input');
  @override
  late final GeneratedColumn<String> input = GeneratedColumn<String>(
    'input',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: true,
  );
  static const VerificationMeta _routingModeMeta = const VerificationMeta(
    'routingMode',
  );
  @override
  late final GeneratedColumn<String> routingMode = GeneratedColumn<String>(
    'routing_mode',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: true,
  );
  static const VerificationMeta _createdAtMeta = const VerificationMeta(
    'createdAt',
  );
  @override
  late final GeneratedColumn<int> createdAt = GeneratedColumn<int>(
    'created_at',
    aliasedName,
    false,
    type: DriftSqlType.int,
    requiredDuringInsert: true,
  );
  static const VerificationMeta _attemptsMeta = const VerificationMeta(
    'attempts',
  );
  @override
  late final GeneratedColumn<int> attempts = GeneratedColumn<int>(
    'attempts',
    aliasedName,
    false,
    type: DriftSqlType.int,
    requiredDuringInsert: true,
  );
  static const VerificationMeta _nextAttemptAtMeta = const VerificationMeta(
    'nextAttemptAt',
  );
  @override
  late final GeneratedColumn<int> nextAttemptAt = GeneratedColumn<int>(
    'next_attempt_at',
    aliasedName,
    false,
    type: DriftSqlType.int,
    requiredDuringInsert: true,
  );
  static const VerificationMeta _lastErrorMeta = const VerificationMeta(
    'lastError',
  );
  @override
  late final GeneratedColumn<String> lastError = GeneratedColumn<String>(
    'last_error',
    aliasedName,
    true,
    type: DriftSqlType.string,
    requiredDuringInsert: false,
  );
  static const VerificationMeta _maxAttemptsMeta = const VerificationMeta(
    'maxAttempts',
  );
  @override
  late final GeneratedColumn<int> maxAttempts = GeneratedColumn<int>(
    'max_attempts',
    aliasedName,
    false,
    type: DriftSqlType.int,
    requiredDuringInsert: false,
    defaultValue: const Constant(10),
  );
  @override
  List<GeneratedColumn> get $columns => [
    id,
    userId,
    groupId,
    agentId,
    input,
    routingMode,
    createdAt,
    attempts,
    nextAttemptAt,
    lastError,
    maxAttempts,
  ];
  @override
  String get aliasedName => _alias ?? actualTableName;
  @override
  String get actualTableName => $name;
  static const String $name = 'outbox_entries';
  @override
  VerificationContext validateIntegrity(
    Insertable<OutboxRow> instance, {
    bool isInserting = false,
  }) {
    final context = VerificationContext();
    final data = instance.toColumns(true);
    if (data.containsKey('id')) {
      context.handle(_idMeta, id.isAcceptableOrUnknown(data['id']!, _idMeta));
    } else if (isInserting) {
      context.missing(_idMeta);
    }
    if (data.containsKey('user_id')) {
      context.handle(
        _userIdMeta,
        userId.isAcceptableOrUnknown(data['user_id']!, _userIdMeta),
      );
    } else if (isInserting) {
      context.missing(_userIdMeta);
    }
    if (data.containsKey('group_id')) {
      context.handle(
        _groupIdMeta,
        groupId.isAcceptableOrUnknown(data['group_id']!, _groupIdMeta),
      );
    }
    if (data.containsKey('agent_id')) {
      context.handle(
        _agentIdMeta,
        agentId.isAcceptableOrUnknown(data['agent_id']!, _agentIdMeta),
      );
    }
    if (data.containsKey('input')) {
      context.handle(
        _inputMeta,
        input.isAcceptableOrUnknown(data['input']!, _inputMeta),
      );
    } else if (isInserting) {
      context.missing(_inputMeta);
    }
    if (data.containsKey('routing_mode')) {
      context.handle(
        _routingModeMeta,
        routingMode.isAcceptableOrUnknown(
          data['routing_mode']!,
          _routingModeMeta,
        ),
      );
    } else if (isInserting) {
      context.missing(_routingModeMeta);
    }
    if (data.containsKey('created_at')) {
      context.handle(
        _createdAtMeta,
        createdAt.isAcceptableOrUnknown(data['created_at']!, _createdAtMeta),
      );
    } else if (isInserting) {
      context.missing(_createdAtMeta);
    }
    if (data.containsKey('attempts')) {
      context.handle(
        _attemptsMeta,
        attempts.isAcceptableOrUnknown(data['attempts']!, _attemptsMeta),
      );
    } else if (isInserting) {
      context.missing(_attemptsMeta);
    }
    if (data.containsKey('next_attempt_at')) {
      context.handle(
        _nextAttemptAtMeta,
        nextAttemptAt.isAcceptableOrUnknown(
          data['next_attempt_at']!,
          _nextAttemptAtMeta,
        ),
      );
    } else if (isInserting) {
      context.missing(_nextAttemptAtMeta);
    }
    if (data.containsKey('last_error')) {
      context.handle(
        _lastErrorMeta,
        lastError.isAcceptableOrUnknown(data['last_error']!, _lastErrorMeta),
      );
    }
    if (data.containsKey('max_attempts')) {
      context.handle(
        _maxAttemptsMeta,
        maxAttempts.isAcceptableOrUnknown(
          data['max_attempts']!,
          _maxAttemptsMeta,
        ),
      );
    }
    return context;
  }

  @override
  Set<GeneratedColumn> get $primaryKey => {id};
  @override
  OutboxRow map(Map<String, dynamic> data, {String? tablePrefix}) {
    final effectivePrefix = tablePrefix != null ? '$tablePrefix.' : '';
    return OutboxRow(
      id: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}id'],
      )!,
      userId: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}user_id'],
      )!,
      groupId: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}group_id'],
      ),
      agentId: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}agent_id'],
      ),
      input: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}input'],
      )!,
      routingMode: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}routing_mode'],
      )!,
      createdAt: attachedDatabase.typeMapping.read(
        DriftSqlType.int,
        data['${effectivePrefix}created_at'],
      )!,
      attempts: attachedDatabase.typeMapping.read(
        DriftSqlType.int,
        data['${effectivePrefix}attempts'],
      )!,
      nextAttemptAt: attachedDatabase.typeMapping.read(
        DriftSqlType.int,
        data['${effectivePrefix}next_attempt_at'],
      )!,
      lastError: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}last_error'],
      ),
      maxAttempts: attachedDatabase.typeMapping.read(
        DriftSqlType.int,
        data['${effectivePrefix}max_attempts'],
      )!,
    );
  }

  @override
  $OutboxEntriesTable createAlias(String alias) {
    return $OutboxEntriesTable(attachedDatabase, alias);
  }
}

class OutboxRow extends DataClass implements Insertable<OutboxRow> {
  final String id;
  final String userId;

  /// null = 无归属入口（服务端分类链判定，见 AGENTS.md §5.5）。
  ///
  /// ⚠️ 必须保留 null 与「空串」的区别：**空串是无效值**，null 才是「让服务端
  /// 判定」。
  final String? groupId;
  final String? agentId;
  final String input;
  final String routingMode;

  /// 入队时刻（毫秒 epoch），**FIFO 排序依据**。
  final int createdAt;

  /// 已尝试投递次数（含首次）。
  final int attempts;

  /// 下次可尝试的时刻（毫秒 epoch）。退避算出。
  final int nextAttemptAt;

  /// 最近一次失败原因（诊断用，UI 可展示）。
  final String? lastError;

  /// 本条目适用**当时的**重试上限（入队时从策略快照）。
  ///
  /// ⚠️ 必须有默认值（`withDefault`）而不是 `nullable`：这是**派生状态**的
  /// 输入，不是「可能没有的数据」——读回 null 会让 `status` 判不出 failed。
  /// 默认值与 `OutboxRetryPolicy.defaultMaxAttempts` 一致。
  final int maxAttempts;
  const OutboxRow({
    required this.id,
    required this.userId,
    this.groupId,
    this.agentId,
    required this.input,
    required this.routingMode,
    required this.createdAt,
    required this.attempts,
    required this.nextAttemptAt,
    this.lastError,
    required this.maxAttempts,
  });
  @override
  Map<String, Expression> toColumns(bool nullToAbsent) {
    final map = <String, Expression>{};
    map['id'] = Variable<String>(id);
    map['user_id'] = Variable<String>(userId);
    if (!nullToAbsent || groupId != null) {
      map['group_id'] = Variable<String>(groupId);
    }
    if (!nullToAbsent || agentId != null) {
      map['agent_id'] = Variable<String>(agentId);
    }
    map['input'] = Variable<String>(input);
    map['routing_mode'] = Variable<String>(routingMode);
    map['created_at'] = Variable<int>(createdAt);
    map['attempts'] = Variable<int>(attempts);
    map['next_attempt_at'] = Variable<int>(nextAttemptAt);
    if (!nullToAbsent || lastError != null) {
      map['last_error'] = Variable<String>(lastError);
    }
    map['max_attempts'] = Variable<int>(maxAttempts);
    return map;
  }

  OutboxEntriesCompanion toCompanion(bool nullToAbsent) {
    return OutboxEntriesCompanion(
      id: Value(id),
      userId: Value(userId),
      groupId: groupId == null && nullToAbsent
          ? const Value.absent()
          : Value(groupId),
      agentId: agentId == null && nullToAbsent
          ? const Value.absent()
          : Value(agentId),
      input: Value(input),
      routingMode: Value(routingMode),
      createdAt: Value(createdAt),
      attempts: Value(attempts),
      nextAttemptAt: Value(nextAttemptAt),
      lastError: lastError == null && nullToAbsent
          ? const Value.absent()
          : Value(lastError),
      maxAttempts: Value(maxAttempts),
    );
  }

  factory OutboxRow.fromJson(
    Map<String, dynamic> json, {
    ValueSerializer? serializer,
  }) {
    serializer ??= driftRuntimeOptions.defaultSerializer;
    return OutboxRow(
      id: serializer.fromJson<String>(json['id']),
      userId: serializer.fromJson<String>(json['userId']),
      groupId: serializer.fromJson<String?>(json['groupId']),
      agentId: serializer.fromJson<String?>(json['agentId']),
      input: serializer.fromJson<String>(json['input']),
      routingMode: serializer.fromJson<String>(json['routingMode']),
      createdAt: serializer.fromJson<int>(json['createdAt']),
      attempts: serializer.fromJson<int>(json['attempts']),
      nextAttemptAt: serializer.fromJson<int>(json['nextAttemptAt']),
      lastError: serializer.fromJson<String?>(json['lastError']),
      maxAttempts: serializer.fromJson<int>(json['maxAttempts']),
    );
  }
  @override
  Map<String, dynamic> toJson({ValueSerializer? serializer}) {
    serializer ??= driftRuntimeOptions.defaultSerializer;
    return <String, dynamic>{
      'id': serializer.toJson<String>(id),
      'userId': serializer.toJson<String>(userId),
      'groupId': serializer.toJson<String?>(groupId),
      'agentId': serializer.toJson<String?>(agentId),
      'input': serializer.toJson<String>(input),
      'routingMode': serializer.toJson<String>(routingMode),
      'createdAt': serializer.toJson<int>(createdAt),
      'attempts': serializer.toJson<int>(attempts),
      'nextAttemptAt': serializer.toJson<int>(nextAttemptAt),
      'lastError': serializer.toJson<String?>(lastError),
      'maxAttempts': serializer.toJson<int>(maxAttempts),
    };
  }

  OutboxRow copyWith({
    String? id,
    String? userId,
    Value<String?> groupId = const Value.absent(),
    Value<String?> agentId = const Value.absent(),
    String? input,
    String? routingMode,
    int? createdAt,
    int? attempts,
    int? nextAttemptAt,
    Value<String?> lastError = const Value.absent(),
    int? maxAttempts,
  }) => OutboxRow(
    id: id ?? this.id,
    userId: userId ?? this.userId,
    groupId: groupId.present ? groupId.value : this.groupId,
    agentId: agentId.present ? agentId.value : this.agentId,
    input: input ?? this.input,
    routingMode: routingMode ?? this.routingMode,
    createdAt: createdAt ?? this.createdAt,
    attempts: attempts ?? this.attempts,
    nextAttemptAt: nextAttemptAt ?? this.nextAttemptAt,
    lastError: lastError.present ? lastError.value : this.lastError,
    maxAttempts: maxAttempts ?? this.maxAttempts,
  );
  OutboxRow copyWithCompanion(OutboxEntriesCompanion data) {
    return OutboxRow(
      id: data.id.present ? data.id.value : this.id,
      userId: data.userId.present ? data.userId.value : this.userId,
      groupId: data.groupId.present ? data.groupId.value : this.groupId,
      agentId: data.agentId.present ? data.agentId.value : this.agentId,
      input: data.input.present ? data.input.value : this.input,
      routingMode: data.routingMode.present
          ? data.routingMode.value
          : this.routingMode,
      createdAt: data.createdAt.present ? data.createdAt.value : this.createdAt,
      attempts: data.attempts.present ? data.attempts.value : this.attempts,
      nextAttemptAt: data.nextAttemptAt.present
          ? data.nextAttemptAt.value
          : this.nextAttemptAt,
      lastError: data.lastError.present ? data.lastError.value : this.lastError,
      maxAttempts: data.maxAttempts.present
          ? data.maxAttempts.value
          : this.maxAttempts,
    );
  }

  @override
  String toString() {
    return (StringBuffer('OutboxRow(')
          ..write('id: $id, ')
          ..write('userId: $userId, ')
          ..write('groupId: $groupId, ')
          ..write('agentId: $agentId, ')
          ..write('input: $input, ')
          ..write('routingMode: $routingMode, ')
          ..write('createdAt: $createdAt, ')
          ..write('attempts: $attempts, ')
          ..write('nextAttemptAt: $nextAttemptAt, ')
          ..write('lastError: $lastError, ')
          ..write('maxAttempts: $maxAttempts')
          ..write(')'))
        .toString();
  }

  @override
  int get hashCode => Object.hash(
    id,
    userId,
    groupId,
    agentId,
    input,
    routingMode,
    createdAt,
    attempts,
    nextAttemptAt,
    lastError,
    maxAttempts,
  );
  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      (other is OutboxRow &&
          other.id == this.id &&
          other.userId == this.userId &&
          other.groupId == this.groupId &&
          other.agentId == this.agentId &&
          other.input == this.input &&
          other.routingMode == this.routingMode &&
          other.createdAt == this.createdAt &&
          other.attempts == this.attempts &&
          other.nextAttemptAt == this.nextAttemptAt &&
          other.lastError == this.lastError &&
          other.maxAttempts == this.maxAttempts);
}

class OutboxEntriesCompanion extends UpdateCompanion<OutboxRow> {
  final Value<String> id;
  final Value<String> userId;
  final Value<String?> groupId;
  final Value<String?> agentId;
  final Value<String> input;
  final Value<String> routingMode;
  final Value<int> createdAt;
  final Value<int> attempts;
  final Value<int> nextAttemptAt;
  final Value<String?> lastError;
  final Value<int> maxAttempts;
  final Value<int> rowid;
  const OutboxEntriesCompanion({
    this.id = const Value.absent(),
    this.userId = const Value.absent(),
    this.groupId = const Value.absent(),
    this.agentId = const Value.absent(),
    this.input = const Value.absent(),
    this.routingMode = const Value.absent(),
    this.createdAt = const Value.absent(),
    this.attempts = const Value.absent(),
    this.nextAttemptAt = const Value.absent(),
    this.lastError = const Value.absent(),
    this.maxAttempts = const Value.absent(),
    this.rowid = const Value.absent(),
  });
  OutboxEntriesCompanion.insert({
    required String id,
    required String userId,
    this.groupId = const Value.absent(),
    this.agentId = const Value.absent(),
    required String input,
    required String routingMode,
    required int createdAt,
    required int attempts,
    required int nextAttemptAt,
    this.lastError = const Value.absent(),
    this.maxAttempts = const Value.absent(),
    this.rowid = const Value.absent(),
  }) : id = Value(id),
       userId = Value(userId),
       input = Value(input),
       routingMode = Value(routingMode),
       createdAt = Value(createdAt),
       attempts = Value(attempts),
       nextAttemptAt = Value(nextAttemptAt);
  static Insertable<OutboxRow> custom({
    Expression<String>? id,
    Expression<String>? userId,
    Expression<String>? groupId,
    Expression<String>? agentId,
    Expression<String>? input,
    Expression<String>? routingMode,
    Expression<int>? createdAt,
    Expression<int>? attempts,
    Expression<int>? nextAttemptAt,
    Expression<String>? lastError,
    Expression<int>? maxAttempts,
    Expression<int>? rowid,
  }) {
    return RawValuesInsertable({
      if (id != null) 'id': id,
      if (userId != null) 'user_id': userId,
      if (groupId != null) 'group_id': groupId,
      if (agentId != null) 'agent_id': agentId,
      if (input != null) 'input': input,
      if (routingMode != null) 'routing_mode': routingMode,
      if (createdAt != null) 'created_at': createdAt,
      if (attempts != null) 'attempts': attempts,
      if (nextAttemptAt != null) 'next_attempt_at': nextAttemptAt,
      if (lastError != null) 'last_error': lastError,
      if (maxAttempts != null) 'max_attempts': maxAttempts,
      if (rowid != null) 'rowid': rowid,
    });
  }

  OutboxEntriesCompanion copyWith({
    Value<String>? id,
    Value<String>? userId,
    Value<String?>? groupId,
    Value<String?>? agentId,
    Value<String>? input,
    Value<String>? routingMode,
    Value<int>? createdAt,
    Value<int>? attempts,
    Value<int>? nextAttemptAt,
    Value<String?>? lastError,
    Value<int>? maxAttempts,
    Value<int>? rowid,
  }) {
    return OutboxEntriesCompanion(
      id: id ?? this.id,
      userId: userId ?? this.userId,
      groupId: groupId ?? this.groupId,
      agentId: agentId ?? this.agentId,
      input: input ?? this.input,
      routingMode: routingMode ?? this.routingMode,
      createdAt: createdAt ?? this.createdAt,
      attempts: attempts ?? this.attempts,
      nextAttemptAt: nextAttemptAt ?? this.nextAttemptAt,
      lastError: lastError ?? this.lastError,
      maxAttempts: maxAttempts ?? this.maxAttempts,
      rowid: rowid ?? this.rowid,
    );
  }

  @override
  Map<String, Expression> toColumns(bool nullToAbsent) {
    final map = <String, Expression>{};
    if (id.present) {
      map['id'] = Variable<String>(id.value);
    }
    if (userId.present) {
      map['user_id'] = Variable<String>(userId.value);
    }
    if (groupId.present) {
      map['group_id'] = Variable<String>(groupId.value);
    }
    if (agentId.present) {
      map['agent_id'] = Variable<String>(agentId.value);
    }
    if (input.present) {
      map['input'] = Variable<String>(input.value);
    }
    if (routingMode.present) {
      map['routing_mode'] = Variable<String>(routingMode.value);
    }
    if (createdAt.present) {
      map['created_at'] = Variable<int>(createdAt.value);
    }
    if (attempts.present) {
      map['attempts'] = Variable<int>(attempts.value);
    }
    if (nextAttemptAt.present) {
      map['next_attempt_at'] = Variable<int>(nextAttemptAt.value);
    }
    if (lastError.present) {
      map['last_error'] = Variable<String>(lastError.value);
    }
    if (maxAttempts.present) {
      map['max_attempts'] = Variable<int>(maxAttempts.value);
    }
    if (rowid.present) {
      map['rowid'] = Variable<int>(rowid.value);
    }
    return map;
  }

  @override
  String toString() {
    return (StringBuffer('OutboxEntriesCompanion(')
          ..write('id: $id, ')
          ..write('userId: $userId, ')
          ..write('groupId: $groupId, ')
          ..write('agentId: $agentId, ')
          ..write('input: $input, ')
          ..write('routingMode: $routingMode, ')
          ..write('createdAt: $createdAt, ')
          ..write('attempts: $attempts, ')
          ..write('nextAttemptAt: $nextAttemptAt, ')
          ..write('lastError: $lastError, ')
          ..write('maxAttempts: $maxAttempts, ')
          ..write('rowid: $rowid')
          ..write(')'))
        .toString();
  }
}

class $PreferencesTable extends Preferences
    with TableInfo<$PreferencesTable, PreferenceRow> {
  @override
  final GeneratedDatabase attachedDatabase;
  final String? _alias;
  $PreferencesTable(this.attachedDatabase, [this._alias]);
  static const VerificationMeta _keyMeta = const VerificationMeta('key');
  @override
  late final GeneratedColumn<String> key = GeneratedColumn<String>(
    'key',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: true,
  );
  static const VerificationMeta _valueMeta = const VerificationMeta('value');
  @override
  late final GeneratedColumn<String> value = GeneratedColumn<String>(
    'value',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: true,
  );
  @override
  List<GeneratedColumn> get $columns => [key, value];
  @override
  String get aliasedName => _alias ?? actualTableName;
  @override
  String get actualTableName => $name;
  static const String $name = 'preferences';
  @override
  VerificationContext validateIntegrity(
    Insertable<PreferenceRow> instance, {
    bool isInserting = false,
  }) {
    final context = VerificationContext();
    final data = instance.toColumns(true);
    if (data.containsKey('key')) {
      context.handle(
        _keyMeta,
        key.isAcceptableOrUnknown(data['key']!, _keyMeta),
      );
    } else if (isInserting) {
      context.missing(_keyMeta);
    }
    if (data.containsKey('value')) {
      context.handle(
        _valueMeta,
        value.isAcceptableOrUnknown(data['value']!, _valueMeta),
      );
    } else if (isInserting) {
      context.missing(_valueMeta);
    }
    return context;
  }

  @override
  Set<GeneratedColumn> get $primaryKey => {key};
  @override
  PreferenceRow map(Map<String, dynamic> data, {String? tablePrefix}) {
    final effectivePrefix = tablePrefix != null ? '$tablePrefix.' : '';
    return PreferenceRow(
      key: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}key'],
      )!,
      value: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}value'],
      )!,
    );
  }

  @override
  $PreferencesTable createAlias(String alias) {
    return $PreferencesTable(attachedDatabase, alias);
  }
}

class PreferenceRow extends DataClass implements Insertable<PreferenceRow> {
  final String key;
  final String value;
  const PreferenceRow({required this.key, required this.value});
  @override
  Map<String, Expression> toColumns(bool nullToAbsent) {
    final map = <String, Expression>{};
    map['key'] = Variable<String>(key);
    map['value'] = Variable<String>(value);
    return map;
  }

  PreferencesCompanion toCompanion(bool nullToAbsent) {
    return PreferencesCompanion(key: Value(key), value: Value(value));
  }

  factory PreferenceRow.fromJson(
    Map<String, dynamic> json, {
    ValueSerializer? serializer,
  }) {
    serializer ??= driftRuntimeOptions.defaultSerializer;
    return PreferenceRow(
      key: serializer.fromJson<String>(json['key']),
      value: serializer.fromJson<String>(json['value']),
    );
  }
  @override
  Map<String, dynamic> toJson({ValueSerializer? serializer}) {
    serializer ??= driftRuntimeOptions.defaultSerializer;
    return <String, dynamic>{
      'key': serializer.toJson<String>(key),
      'value': serializer.toJson<String>(value),
    };
  }

  PreferenceRow copyWith({String? key, String? value}) =>
      PreferenceRow(key: key ?? this.key, value: value ?? this.value);
  PreferenceRow copyWithCompanion(PreferencesCompanion data) {
    return PreferenceRow(
      key: data.key.present ? data.key.value : this.key,
      value: data.value.present ? data.value.value : this.value,
    );
  }

  @override
  String toString() {
    return (StringBuffer('PreferenceRow(')
          ..write('key: $key, ')
          ..write('value: $value')
          ..write(')'))
        .toString();
  }

  @override
  int get hashCode => Object.hash(key, value);
  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      (other is PreferenceRow &&
          other.key == this.key &&
          other.value == this.value);
}

class PreferencesCompanion extends UpdateCompanion<PreferenceRow> {
  final Value<String> key;
  final Value<String> value;
  final Value<int> rowid;
  const PreferencesCompanion({
    this.key = const Value.absent(),
    this.value = const Value.absent(),
    this.rowid = const Value.absent(),
  });
  PreferencesCompanion.insert({
    required String key,
    required String value,
    this.rowid = const Value.absent(),
  }) : key = Value(key),
       value = Value(value);
  static Insertable<PreferenceRow> custom({
    Expression<String>? key,
    Expression<String>? value,
    Expression<int>? rowid,
  }) {
    return RawValuesInsertable({
      if (key != null) 'key': key,
      if (value != null) 'value': value,
      if (rowid != null) 'rowid': rowid,
    });
  }

  PreferencesCompanion copyWith({
    Value<String>? key,
    Value<String>? value,
    Value<int>? rowid,
  }) {
    return PreferencesCompanion(
      key: key ?? this.key,
      value: value ?? this.value,
      rowid: rowid ?? this.rowid,
    );
  }

  @override
  Map<String, Expression> toColumns(bool nullToAbsent) {
    final map = <String, Expression>{};
    if (key.present) {
      map['key'] = Variable<String>(key.value);
    }
    if (value.present) {
      map['value'] = Variable<String>(value.value);
    }
    if (rowid.present) {
      map['rowid'] = Variable<int>(rowid.value);
    }
    return map;
  }

  @override
  String toString() {
    return (StringBuffer('PreferencesCompanion(')
          ..write('key: $key, ')
          ..write('value: $value, ')
          ..write('rowid: $rowid')
          ..write(')'))
        .toString();
  }
}

abstract class _$AppDatabase extends GeneratedDatabase {
  _$AppDatabase(QueryExecutor e) : super(e);
  $AppDatabaseManager get managers => $AppDatabaseManager(this);
  late final $SyncCursorsTable syncCursors = $SyncCursorsTable(this);
  late final $SyncedFilesTable syncedFiles = $SyncedFilesTable(this);
  late final $SyncBindingsTable syncBindings = $SyncBindingsTable(this);
  late final $CachedGroupsTable cachedGroups = $CachedGroupsTable(this);
  late final $CachedEventsTable cachedEvents = $CachedEventsTable(this);
  late final $OutboxEntriesTable outboxEntries = $OutboxEntriesTable(this);
  late final $PreferencesTable preferences = $PreferencesTable(this);
  @override
  Iterable<TableInfo<Table, Object?>> get allTables =>
      allSchemaEntities.whereType<TableInfo<Table, Object?>>();
  @override
  List<DatabaseSchemaEntity> get allSchemaEntities => [
    syncCursors,
    syncedFiles,
    syncBindings,
    cachedGroups,
    cachedEvents,
    outboxEntries,
    preferences,
  ];
}

typedef $$SyncCursorsTableCreateCompanionBuilder =
    SyncCursorsCompanion Function({
      required String stateKey,
      Value<String?> cursor,
      Value<int> rowid,
    });
typedef $$SyncCursorsTableUpdateCompanionBuilder =
    SyncCursorsCompanion Function({
      Value<String> stateKey,
      Value<String?> cursor,
      Value<int> rowid,
    });

class $$SyncCursorsTableFilterComposer
    extends Composer<_$AppDatabase, $SyncCursorsTable> {
  $$SyncCursorsTableFilterComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  ColumnFilters<String> get stateKey => $composableBuilder(
    column: $table.stateKey,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get cursor => $composableBuilder(
    column: $table.cursor,
    builder: (column) => ColumnFilters(column),
  );
}

class $$SyncCursorsTableOrderingComposer
    extends Composer<_$AppDatabase, $SyncCursorsTable> {
  $$SyncCursorsTableOrderingComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  ColumnOrderings<String> get stateKey => $composableBuilder(
    column: $table.stateKey,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get cursor => $composableBuilder(
    column: $table.cursor,
    builder: (column) => ColumnOrderings(column),
  );
}

class $$SyncCursorsTableAnnotationComposer
    extends Composer<_$AppDatabase, $SyncCursorsTable> {
  $$SyncCursorsTableAnnotationComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  GeneratedColumn<String> get stateKey =>
      $composableBuilder(column: $table.stateKey, builder: (column) => column);

  GeneratedColumn<String> get cursor =>
      $composableBuilder(column: $table.cursor, builder: (column) => column);
}

class $$SyncCursorsTableTableManager
    extends
        RootTableManager<
          _$AppDatabase,
          $SyncCursorsTable,
          SyncCursorRow,
          $$SyncCursorsTableFilterComposer,
          $$SyncCursorsTableOrderingComposer,
          $$SyncCursorsTableAnnotationComposer,
          $$SyncCursorsTableCreateCompanionBuilder,
          $$SyncCursorsTableUpdateCompanionBuilder,
          (
            SyncCursorRow,
            BaseReferences<_$AppDatabase, $SyncCursorsTable, SyncCursorRow>,
          ),
          SyncCursorRow,
          PrefetchHooks Function()
        > {
  $$SyncCursorsTableTableManager(_$AppDatabase db, $SyncCursorsTable table)
    : super(
        TableManagerState(
          db: db,
          table: table,
          createFilteringComposer: () =>
              $$SyncCursorsTableFilterComposer($db: db, $table: table),
          createOrderingComposer: () =>
              $$SyncCursorsTableOrderingComposer($db: db, $table: table),
          createComputedFieldComposer: () =>
              $$SyncCursorsTableAnnotationComposer($db: db, $table: table),
          updateCompanionCallback:
              ({
                Value<String> stateKey = const Value.absent(),
                Value<String?> cursor = const Value.absent(),
                Value<int> rowid = const Value.absent(),
              }) => SyncCursorsCompanion(
                stateKey: stateKey,
                cursor: cursor,
                rowid: rowid,
              ),
          createCompanionCallback:
              ({
                required String stateKey,
                Value<String?> cursor = const Value.absent(),
                Value<int> rowid = const Value.absent(),
              }) => SyncCursorsCompanion.insert(
                stateKey: stateKey,
                cursor: cursor,
                rowid: rowid,
              ),
          withReferenceMapper: (p0) => p0
              .map((e) => (e.readTable(table), BaseReferences(db, table, e)))
              .toList(),
          prefetchHooksCallback: null,
        ),
      );
}

typedef $$SyncCursorsTableProcessedTableManager =
    ProcessedTableManager<
      _$AppDatabase,
      $SyncCursorsTable,
      SyncCursorRow,
      $$SyncCursorsTableFilterComposer,
      $$SyncCursorsTableOrderingComposer,
      $$SyncCursorsTableAnnotationComposer,
      $$SyncCursorsTableCreateCompanionBuilder,
      $$SyncCursorsTableUpdateCompanionBuilder,
      (
        SyncCursorRow,
        BaseReferences<_$AppDatabase, $SyncCursorsTable, SyncCursorRow>,
      ),
      SyncCursorRow,
      PrefetchHooks Function()
    >;
typedef $$SyncedFilesTableCreateCompanionBuilder =
    SyncedFilesCompanion Function({
      required String stateKey,
      required String relPath,
      Value<String?> etag,
      required int size,
      Value<String?> updatedAt,
      Value<String?> contentHash,
      Value<int> rowid,
    });
typedef $$SyncedFilesTableUpdateCompanionBuilder =
    SyncedFilesCompanion Function({
      Value<String> stateKey,
      Value<String> relPath,
      Value<String?> etag,
      Value<int> size,
      Value<String?> updatedAt,
      Value<String?> contentHash,
      Value<int> rowid,
    });

class $$SyncedFilesTableFilterComposer
    extends Composer<_$AppDatabase, $SyncedFilesTable> {
  $$SyncedFilesTableFilterComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  ColumnFilters<String> get stateKey => $composableBuilder(
    column: $table.stateKey,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get relPath => $composableBuilder(
    column: $table.relPath,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get etag => $composableBuilder(
    column: $table.etag,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<int> get size => $composableBuilder(
    column: $table.size,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get updatedAt => $composableBuilder(
    column: $table.updatedAt,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get contentHash => $composableBuilder(
    column: $table.contentHash,
    builder: (column) => ColumnFilters(column),
  );
}

class $$SyncedFilesTableOrderingComposer
    extends Composer<_$AppDatabase, $SyncedFilesTable> {
  $$SyncedFilesTableOrderingComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  ColumnOrderings<String> get stateKey => $composableBuilder(
    column: $table.stateKey,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get relPath => $composableBuilder(
    column: $table.relPath,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get etag => $composableBuilder(
    column: $table.etag,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<int> get size => $composableBuilder(
    column: $table.size,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get updatedAt => $composableBuilder(
    column: $table.updatedAt,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get contentHash => $composableBuilder(
    column: $table.contentHash,
    builder: (column) => ColumnOrderings(column),
  );
}

class $$SyncedFilesTableAnnotationComposer
    extends Composer<_$AppDatabase, $SyncedFilesTable> {
  $$SyncedFilesTableAnnotationComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  GeneratedColumn<String> get stateKey =>
      $composableBuilder(column: $table.stateKey, builder: (column) => column);

  GeneratedColumn<String> get relPath =>
      $composableBuilder(column: $table.relPath, builder: (column) => column);

  GeneratedColumn<String> get etag =>
      $composableBuilder(column: $table.etag, builder: (column) => column);

  GeneratedColumn<int> get size =>
      $composableBuilder(column: $table.size, builder: (column) => column);

  GeneratedColumn<String> get updatedAt =>
      $composableBuilder(column: $table.updatedAt, builder: (column) => column);

  GeneratedColumn<String> get contentHash => $composableBuilder(
    column: $table.contentHash,
    builder: (column) => column,
  );
}

class $$SyncedFilesTableTableManager
    extends
        RootTableManager<
          _$AppDatabase,
          $SyncedFilesTable,
          SyncedFileRow,
          $$SyncedFilesTableFilterComposer,
          $$SyncedFilesTableOrderingComposer,
          $$SyncedFilesTableAnnotationComposer,
          $$SyncedFilesTableCreateCompanionBuilder,
          $$SyncedFilesTableUpdateCompanionBuilder,
          (
            SyncedFileRow,
            BaseReferences<_$AppDatabase, $SyncedFilesTable, SyncedFileRow>,
          ),
          SyncedFileRow,
          PrefetchHooks Function()
        > {
  $$SyncedFilesTableTableManager(_$AppDatabase db, $SyncedFilesTable table)
    : super(
        TableManagerState(
          db: db,
          table: table,
          createFilteringComposer: () =>
              $$SyncedFilesTableFilterComposer($db: db, $table: table),
          createOrderingComposer: () =>
              $$SyncedFilesTableOrderingComposer($db: db, $table: table),
          createComputedFieldComposer: () =>
              $$SyncedFilesTableAnnotationComposer($db: db, $table: table),
          updateCompanionCallback:
              ({
                Value<String> stateKey = const Value.absent(),
                Value<String> relPath = const Value.absent(),
                Value<String?> etag = const Value.absent(),
                Value<int> size = const Value.absent(),
                Value<String?> updatedAt = const Value.absent(),
                Value<String?> contentHash = const Value.absent(),
                Value<int> rowid = const Value.absent(),
              }) => SyncedFilesCompanion(
                stateKey: stateKey,
                relPath: relPath,
                etag: etag,
                size: size,
                updatedAt: updatedAt,
                contentHash: contentHash,
                rowid: rowid,
              ),
          createCompanionCallback:
              ({
                required String stateKey,
                required String relPath,
                Value<String?> etag = const Value.absent(),
                required int size,
                Value<String?> updatedAt = const Value.absent(),
                Value<String?> contentHash = const Value.absent(),
                Value<int> rowid = const Value.absent(),
              }) => SyncedFilesCompanion.insert(
                stateKey: stateKey,
                relPath: relPath,
                etag: etag,
                size: size,
                updatedAt: updatedAt,
                contentHash: contentHash,
                rowid: rowid,
              ),
          withReferenceMapper: (p0) => p0
              .map((e) => (e.readTable(table), BaseReferences(db, table, e)))
              .toList(),
          prefetchHooksCallback: null,
        ),
      );
}

typedef $$SyncedFilesTableProcessedTableManager =
    ProcessedTableManager<
      _$AppDatabase,
      $SyncedFilesTable,
      SyncedFileRow,
      $$SyncedFilesTableFilterComposer,
      $$SyncedFilesTableOrderingComposer,
      $$SyncedFilesTableAnnotationComposer,
      $$SyncedFilesTableCreateCompanionBuilder,
      $$SyncedFilesTableUpdateCompanionBuilder,
      (
        SyncedFileRow,
        BaseReferences<_$AppDatabase, $SyncedFilesTable, SyncedFileRow>,
      ),
      SyncedFileRow,
      PrefetchHooks Function()
    >;
typedef $$SyncBindingsTableCreateCompanionBuilder =
    SyncBindingsCompanion Function({Value<int> id, Value<String?> localRoot});
typedef $$SyncBindingsTableUpdateCompanionBuilder =
    SyncBindingsCompanion Function({Value<int> id, Value<String?> localRoot});

class $$SyncBindingsTableFilterComposer
    extends Composer<_$AppDatabase, $SyncBindingsTable> {
  $$SyncBindingsTableFilterComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  ColumnFilters<int> get id => $composableBuilder(
    column: $table.id,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get localRoot => $composableBuilder(
    column: $table.localRoot,
    builder: (column) => ColumnFilters(column),
  );
}

class $$SyncBindingsTableOrderingComposer
    extends Composer<_$AppDatabase, $SyncBindingsTable> {
  $$SyncBindingsTableOrderingComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  ColumnOrderings<int> get id => $composableBuilder(
    column: $table.id,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get localRoot => $composableBuilder(
    column: $table.localRoot,
    builder: (column) => ColumnOrderings(column),
  );
}

class $$SyncBindingsTableAnnotationComposer
    extends Composer<_$AppDatabase, $SyncBindingsTable> {
  $$SyncBindingsTableAnnotationComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  GeneratedColumn<int> get id =>
      $composableBuilder(column: $table.id, builder: (column) => column);

  GeneratedColumn<String> get localRoot =>
      $composableBuilder(column: $table.localRoot, builder: (column) => column);
}

class $$SyncBindingsTableTableManager
    extends
        RootTableManager<
          _$AppDatabase,
          $SyncBindingsTable,
          SyncBindingRow,
          $$SyncBindingsTableFilterComposer,
          $$SyncBindingsTableOrderingComposer,
          $$SyncBindingsTableAnnotationComposer,
          $$SyncBindingsTableCreateCompanionBuilder,
          $$SyncBindingsTableUpdateCompanionBuilder,
          (
            SyncBindingRow,
            BaseReferences<_$AppDatabase, $SyncBindingsTable, SyncBindingRow>,
          ),
          SyncBindingRow,
          PrefetchHooks Function()
        > {
  $$SyncBindingsTableTableManager(_$AppDatabase db, $SyncBindingsTable table)
    : super(
        TableManagerState(
          db: db,
          table: table,
          createFilteringComposer: () =>
              $$SyncBindingsTableFilterComposer($db: db, $table: table),
          createOrderingComposer: () =>
              $$SyncBindingsTableOrderingComposer($db: db, $table: table),
          createComputedFieldComposer: () =>
              $$SyncBindingsTableAnnotationComposer($db: db, $table: table),
          updateCompanionCallback: ({
            Value<int> id = const Value.absent(),
            Value<String?> localRoot = const Value.absent(),
          }) => SyncBindingsCompanion(id: id, localRoot: localRoot),
          createCompanionCallback: ({
            Value<int> id = const Value.absent(),
            Value<String?> localRoot = const Value.absent(),
          }) => SyncBindingsCompanion.insert(id: id, localRoot: localRoot),
          withReferenceMapper: (p0) => p0
              .map((e) => (e.readTable(table), BaseReferences(db, table, e)))
              .toList(),
          prefetchHooksCallback: null,
        ),
      );
}

typedef $$SyncBindingsTableProcessedTableManager =
    ProcessedTableManager<
      _$AppDatabase,
      $SyncBindingsTable,
      SyncBindingRow,
      $$SyncBindingsTableFilterComposer,
      $$SyncBindingsTableOrderingComposer,
      $$SyncBindingsTableAnnotationComposer,
      $$SyncBindingsTableCreateCompanionBuilder,
      $$SyncBindingsTableUpdateCompanionBuilder,
      (
        SyncBindingRow,
        BaseReferences<_$AppDatabase, $SyncBindingsTable, SyncBindingRow>,
      ),
      SyncBindingRow,
      PrefetchHooks Function()
    >;
typedef $$CachedGroupsTableCreateCompanionBuilder =
    CachedGroupsCompanion Function({
      required String id,
      required String userId,
      required String payload,
      Value<String?> updatedAt,
      required int fetchedAt,
      Value<int> rowid,
    });
typedef $$CachedGroupsTableUpdateCompanionBuilder =
    CachedGroupsCompanion Function({
      Value<String> id,
      Value<String> userId,
      Value<String> payload,
      Value<String?> updatedAt,
      Value<int> fetchedAt,
      Value<int> rowid,
    });

class $$CachedGroupsTableFilterComposer
    extends Composer<_$AppDatabase, $CachedGroupsTable> {
  $$CachedGroupsTableFilterComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  ColumnFilters<String> get id => $composableBuilder(
    column: $table.id,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get userId => $composableBuilder(
    column: $table.userId,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get payload => $composableBuilder(
    column: $table.payload,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get updatedAt => $composableBuilder(
    column: $table.updatedAt,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<int> get fetchedAt => $composableBuilder(
    column: $table.fetchedAt,
    builder: (column) => ColumnFilters(column),
  );
}

class $$CachedGroupsTableOrderingComposer
    extends Composer<_$AppDatabase, $CachedGroupsTable> {
  $$CachedGroupsTableOrderingComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  ColumnOrderings<String> get id => $composableBuilder(
    column: $table.id,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get userId => $composableBuilder(
    column: $table.userId,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get payload => $composableBuilder(
    column: $table.payload,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get updatedAt => $composableBuilder(
    column: $table.updatedAt,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<int> get fetchedAt => $composableBuilder(
    column: $table.fetchedAt,
    builder: (column) => ColumnOrderings(column),
  );
}

class $$CachedGroupsTableAnnotationComposer
    extends Composer<_$AppDatabase, $CachedGroupsTable> {
  $$CachedGroupsTableAnnotationComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  GeneratedColumn<String> get id =>
      $composableBuilder(column: $table.id, builder: (column) => column);

  GeneratedColumn<String> get userId =>
      $composableBuilder(column: $table.userId, builder: (column) => column);

  GeneratedColumn<String> get payload =>
      $composableBuilder(column: $table.payload, builder: (column) => column);

  GeneratedColumn<String> get updatedAt =>
      $composableBuilder(column: $table.updatedAt, builder: (column) => column);

  GeneratedColumn<int> get fetchedAt =>
      $composableBuilder(column: $table.fetchedAt, builder: (column) => column);
}

class $$CachedGroupsTableTableManager
    extends
        RootTableManager<
          _$AppDatabase,
          $CachedGroupsTable,
          CachedGroupRow,
          $$CachedGroupsTableFilterComposer,
          $$CachedGroupsTableOrderingComposer,
          $$CachedGroupsTableAnnotationComposer,
          $$CachedGroupsTableCreateCompanionBuilder,
          $$CachedGroupsTableUpdateCompanionBuilder,
          (
            CachedGroupRow,
            BaseReferences<_$AppDatabase, $CachedGroupsTable, CachedGroupRow>,
          ),
          CachedGroupRow,
          PrefetchHooks Function()
        > {
  $$CachedGroupsTableTableManager(_$AppDatabase db, $CachedGroupsTable table)
    : super(
        TableManagerState(
          db: db,
          table: table,
          createFilteringComposer: () =>
              $$CachedGroupsTableFilterComposer($db: db, $table: table),
          createOrderingComposer: () =>
              $$CachedGroupsTableOrderingComposer($db: db, $table: table),
          createComputedFieldComposer: () =>
              $$CachedGroupsTableAnnotationComposer($db: db, $table: table),
          updateCompanionCallback:
              ({
                Value<String> id = const Value.absent(),
                Value<String> userId = const Value.absent(),
                Value<String> payload = const Value.absent(),
                Value<String?> updatedAt = const Value.absent(),
                Value<int> fetchedAt = const Value.absent(),
                Value<int> rowid = const Value.absent(),
              }) => CachedGroupsCompanion(
                id: id,
                userId: userId,
                payload: payload,
                updatedAt: updatedAt,
                fetchedAt: fetchedAt,
                rowid: rowid,
              ),
          createCompanionCallback:
              ({
                required String id,
                required String userId,
                required String payload,
                Value<String?> updatedAt = const Value.absent(),
                required int fetchedAt,
                Value<int> rowid = const Value.absent(),
              }) => CachedGroupsCompanion.insert(
                id: id,
                userId: userId,
                payload: payload,
                updatedAt: updatedAt,
                fetchedAt: fetchedAt,
                rowid: rowid,
              ),
          withReferenceMapper: (p0) => p0
              .map((e) => (e.readTable(table), BaseReferences(db, table, e)))
              .toList(),
          prefetchHooksCallback: null,
        ),
      );
}

typedef $$CachedGroupsTableProcessedTableManager =
    ProcessedTableManager<
      _$AppDatabase,
      $CachedGroupsTable,
      CachedGroupRow,
      $$CachedGroupsTableFilterComposer,
      $$CachedGroupsTableOrderingComposer,
      $$CachedGroupsTableAnnotationComposer,
      $$CachedGroupsTableCreateCompanionBuilder,
      $$CachedGroupsTableUpdateCompanionBuilder,
      (
        CachedGroupRow,
        BaseReferences<_$AppDatabase, $CachedGroupsTable, CachedGroupRow>,
      ),
      CachedGroupRow,
      PrefetchHooks Function()
    >;
typedef $$CachedEventsTableCreateCompanionBuilder =
    CachedEventsCompanion Function({
      required String groupId,
      required int globalSeq,
      required String payload,
      required int cachedAt,
      required int lastAccessedAt,
      Value<int> rowid,
    });
typedef $$CachedEventsTableUpdateCompanionBuilder =
    CachedEventsCompanion Function({
      Value<String> groupId,
      Value<int> globalSeq,
      Value<String> payload,
      Value<int> cachedAt,
      Value<int> lastAccessedAt,
      Value<int> rowid,
    });

class $$CachedEventsTableFilterComposer
    extends Composer<_$AppDatabase, $CachedEventsTable> {
  $$CachedEventsTableFilterComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  ColumnFilters<String> get groupId => $composableBuilder(
    column: $table.groupId,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<int> get globalSeq => $composableBuilder(
    column: $table.globalSeq,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get payload => $composableBuilder(
    column: $table.payload,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<int> get cachedAt => $composableBuilder(
    column: $table.cachedAt,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<int> get lastAccessedAt => $composableBuilder(
    column: $table.lastAccessedAt,
    builder: (column) => ColumnFilters(column),
  );
}

class $$CachedEventsTableOrderingComposer
    extends Composer<_$AppDatabase, $CachedEventsTable> {
  $$CachedEventsTableOrderingComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  ColumnOrderings<String> get groupId => $composableBuilder(
    column: $table.groupId,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<int> get globalSeq => $composableBuilder(
    column: $table.globalSeq,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get payload => $composableBuilder(
    column: $table.payload,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<int> get cachedAt => $composableBuilder(
    column: $table.cachedAt,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<int> get lastAccessedAt => $composableBuilder(
    column: $table.lastAccessedAt,
    builder: (column) => ColumnOrderings(column),
  );
}

class $$CachedEventsTableAnnotationComposer
    extends Composer<_$AppDatabase, $CachedEventsTable> {
  $$CachedEventsTableAnnotationComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  GeneratedColumn<String> get groupId =>
      $composableBuilder(column: $table.groupId, builder: (column) => column);

  GeneratedColumn<int> get globalSeq =>
      $composableBuilder(column: $table.globalSeq, builder: (column) => column);

  GeneratedColumn<String> get payload =>
      $composableBuilder(column: $table.payload, builder: (column) => column);

  GeneratedColumn<int> get cachedAt =>
      $composableBuilder(column: $table.cachedAt, builder: (column) => column);

  GeneratedColumn<int> get lastAccessedAt => $composableBuilder(
    column: $table.lastAccessedAt,
    builder: (column) => column,
  );
}

class $$CachedEventsTableTableManager
    extends
        RootTableManager<
          _$AppDatabase,
          $CachedEventsTable,
          CachedEventRow,
          $$CachedEventsTableFilterComposer,
          $$CachedEventsTableOrderingComposer,
          $$CachedEventsTableAnnotationComposer,
          $$CachedEventsTableCreateCompanionBuilder,
          $$CachedEventsTableUpdateCompanionBuilder,
          (
            CachedEventRow,
            BaseReferences<_$AppDatabase, $CachedEventsTable, CachedEventRow>,
          ),
          CachedEventRow,
          PrefetchHooks Function()
        > {
  $$CachedEventsTableTableManager(_$AppDatabase db, $CachedEventsTable table)
    : super(
        TableManagerState(
          db: db,
          table: table,
          createFilteringComposer: () =>
              $$CachedEventsTableFilterComposer($db: db, $table: table),
          createOrderingComposer: () =>
              $$CachedEventsTableOrderingComposer($db: db, $table: table),
          createComputedFieldComposer: () =>
              $$CachedEventsTableAnnotationComposer($db: db, $table: table),
          updateCompanionCallback:
              ({
                Value<String> groupId = const Value.absent(),
                Value<int> globalSeq = const Value.absent(),
                Value<String> payload = const Value.absent(),
                Value<int> cachedAt = const Value.absent(),
                Value<int> lastAccessedAt = const Value.absent(),
                Value<int> rowid = const Value.absent(),
              }) => CachedEventsCompanion(
                groupId: groupId,
                globalSeq: globalSeq,
                payload: payload,
                cachedAt: cachedAt,
                lastAccessedAt: lastAccessedAt,
                rowid: rowid,
              ),
          createCompanionCallback:
              ({
                required String groupId,
                required int globalSeq,
                required String payload,
                required int cachedAt,
                required int lastAccessedAt,
                Value<int> rowid = const Value.absent(),
              }) => CachedEventsCompanion.insert(
                groupId: groupId,
                globalSeq: globalSeq,
                payload: payload,
                cachedAt: cachedAt,
                lastAccessedAt: lastAccessedAt,
                rowid: rowid,
              ),
          withReferenceMapper: (p0) => p0
              .map((e) => (e.readTable(table), BaseReferences(db, table, e)))
              .toList(),
          prefetchHooksCallback: null,
        ),
      );
}

typedef $$CachedEventsTableProcessedTableManager =
    ProcessedTableManager<
      _$AppDatabase,
      $CachedEventsTable,
      CachedEventRow,
      $$CachedEventsTableFilterComposer,
      $$CachedEventsTableOrderingComposer,
      $$CachedEventsTableAnnotationComposer,
      $$CachedEventsTableCreateCompanionBuilder,
      $$CachedEventsTableUpdateCompanionBuilder,
      (
        CachedEventRow,
        BaseReferences<_$AppDatabase, $CachedEventsTable, CachedEventRow>,
      ),
      CachedEventRow,
      PrefetchHooks Function()
    >;
typedef $$OutboxEntriesTableCreateCompanionBuilder =
    OutboxEntriesCompanion Function({
      required String id,
      required String userId,
      Value<String?> groupId,
      Value<String?> agentId,
      required String input,
      required String routingMode,
      required int createdAt,
      required int attempts,
      required int nextAttemptAt,
      Value<String?> lastError,
      Value<int> maxAttempts,
      Value<int> rowid,
    });
typedef $$OutboxEntriesTableUpdateCompanionBuilder =
    OutboxEntriesCompanion Function({
      Value<String> id,
      Value<String> userId,
      Value<String?> groupId,
      Value<String?> agentId,
      Value<String> input,
      Value<String> routingMode,
      Value<int> createdAt,
      Value<int> attempts,
      Value<int> nextAttemptAt,
      Value<String?> lastError,
      Value<int> maxAttempts,
      Value<int> rowid,
    });

class $$OutboxEntriesTableFilterComposer
    extends Composer<_$AppDatabase, $OutboxEntriesTable> {
  $$OutboxEntriesTableFilterComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  ColumnFilters<String> get id => $composableBuilder(
    column: $table.id,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get userId => $composableBuilder(
    column: $table.userId,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get groupId => $composableBuilder(
    column: $table.groupId,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get agentId => $composableBuilder(
    column: $table.agentId,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get input => $composableBuilder(
    column: $table.input,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get routingMode => $composableBuilder(
    column: $table.routingMode,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<int> get createdAt => $composableBuilder(
    column: $table.createdAt,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<int> get attempts => $composableBuilder(
    column: $table.attempts,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<int> get nextAttemptAt => $composableBuilder(
    column: $table.nextAttemptAt,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get lastError => $composableBuilder(
    column: $table.lastError,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<int> get maxAttempts => $composableBuilder(
    column: $table.maxAttempts,
    builder: (column) => ColumnFilters(column),
  );
}

class $$OutboxEntriesTableOrderingComposer
    extends Composer<_$AppDatabase, $OutboxEntriesTable> {
  $$OutboxEntriesTableOrderingComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  ColumnOrderings<String> get id => $composableBuilder(
    column: $table.id,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get userId => $composableBuilder(
    column: $table.userId,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get groupId => $composableBuilder(
    column: $table.groupId,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get agentId => $composableBuilder(
    column: $table.agentId,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get input => $composableBuilder(
    column: $table.input,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get routingMode => $composableBuilder(
    column: $table.routingMode,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<int> get createdAt => $composableBuilder(
    column: $table.createdAt,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<int> get attempts => $composableBuilder(
    column: $table.attempts,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<int> get nextAttemptAt => $composableBuilder(
    column: $table.nextAttemptAt,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get lastError => $composableBuilder(
    column: $table.lastError,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<int> get maxAttempts => $composableBuilder(
    column: $table.maxAttempts,
    builder: (column) => ColumnOrderings(column),
  );
}

class $$OutboxEntriesTableAnnotationComposer
    extends Composer<_$AppDatabase, $OutboxEntriesTable> {
  $$OutboxEntriesTableAnnotationComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  GeneratedColumn<String> get id =>
      $composableBuilder(column: $table.id, builder: (column) => column);

  GeneratedColumn<String> get userId =>
      $composableBuilder(column: $table.userId, builder: (column) => column);

  GeneratedColumn<String> get groupId =>
      $composableBuilder(column: $table.groupId, builder: (column) => column);

  GeneratedColumn<String> get agentId =>
      $composableBuilder(column: $table.agentId, builder: (column) => column);

  GeneratedColumn<String> get input =>
      $composableBuilder(column: $table.input, builder: (column) => column);

  GeneratedColumn<String> get routingMode => $composableBuilder(
    column: $table.routingMode,
    builder: (column) => column,
  );

  GeneratedColumn<int> get createdAt =>
      $composableBuilder(column: $table.createdAt, builder: (column) => column);

  GeneratedColumn<int> get attempts =>
      $composableBuilder(column: $table.attempts, builder: (column) => column);

  GeneratedColumn<int> get nextAttemptAt => $composableBuilder(
    column: $table.nextAttemptAt,
    builder: (column) => column,
  );

  GeneratedColumn<String> get lastError =>
      $composableBuilder(column: $table.lastError, builder: (column) => column);

  GeneratedColumn<int> get maxAttempts => $composableBuilder(
    column: $table.maxAttempts,
    builder: (column) => column,
  );
}

class $$OutboxEntriesTableTableManager
    extends
        RootTableManager<
          _$AppDatabase,
          $OutboxEntriesTable,
          OutboxRow,
          $$OutboxEntriesTableFilterComposer,
          $$OutboxEntriesTableOrderingComposer,
          $$OutboxEntriesTableAnnotationComposer,
          $$OutboxEntriesTableCreateCompanionBuilder,
          $$OutboxEntriesTableUpdateCompanionBuilder,
          (
            OutboxRow,
            BaseReferences<_$AppDatabase, $OutboxEntriesTable, OutboxRow>,
          ),
          OutboxRow,
          PrefetchHooks Function()
        > {
  $$OutboxEntriesTableTableManager(_$AppDatabase db, $OutboxEntriesTable table)
    : super(
        TableManagerState(
          db: db,
          table: table,
          createFilteringComposer: () =>
              $$OutboxEntriesTableFilterComposer($db: db, $table: table),
          createOrderingComposer: () =>
              $$OutboxEntriesTableOrderingComposer($db: db, $table: table),
          createComputedFieldComposer: () =>
              $$OutboxEntriesTableAnnotationComposer($db: db, $table: table),
          updateCompanionCallback:
              ({
                Value<String> id = const Value.absent(),
                Value<String> userId = const Value.absent(),
                Value<String?> groupId = const Value.absent(),
                Value<String?> agentId = const Value.absent(),
                Value<String> input = const Value.absent(),
                Value<String> routingMode = const Value.absent(),
                Value<int> createdAt = const Value.absent(),
                Value<int> attempts = const Value.absent(),
                Value<int> nextAttemptAt = const Value.absent(),
                Value<String?> lastError = const Value.absent(),
                Value<int> maxAttempts = const Value.absent(),
                Value<int> rowid = const Value.absent(),
              }) => OutboxEntriesCompanion(
                id: id,
                userId: userId,
                groupId: groupId,
                agentId: agentId,
                input: input,
                routingMode: routingMode,
                createdAt: createdAt,
                attempts: attempts,
                nextAttemptAt: nextAttemptAt,
                lastError: lastError,
                maxAttempts: maxAttempts,
                rowid: rowid,
              ),
          createCompanionCallback:
              ({
                required String id,
                required String userId,
                Value<String?> groupId = const Value.absent(),
                Value<String?> agentId = const Value.absent(),
                required String input,
                required String routingMode,
                required int createdAt,
                required int attempts,
                required int nextAttemptAt,
                Value<String?> lastError = const Value.absent(),
                Value<int> maxAttempts = const Value.absent(),
                Value<int> rowid = const Value.absent(),
              }) => OutboxEntriesCompanion.insert(
                id: id,
                userId: userId,
                groupId: groupId,
                agentId: agentId,
                input: input,
                routingMode: routingMode,
                createdAt: createdAt,
                attempts: attempts,
                nextAttemptAt: nextAttemptAt,
                lastError: lastError,
                maxAttempts: maxAttempts,
                rowid: rowid,
              ),
          withReferenceMapper: (p0) => p0
              .map((e) => (e.readTable(table), BaseReferences(db, table, e)))
              .toList(),
          prefetchHooksCallback: null,
        ),
      );
}

typedef $$OutboxEntriesTableProcessedTableManager =
    ProcessedTableManager<
      _$AppDatabase,
      $OutboxEntriesTable,
      OutboxRow,
      $$OutboxEntriesTableFilterComposer,
      $$OutboxEntriesTableOrderingComposer,
      $$OutboxEntriesTableAnnotationComposer,
      $$OutboxEntriesTableCreateCompanionBuilder,
      $$OutboxEntriesTableUpdateCompanionBuilder,
      (
        OutboxRow,
        BaseReferences<_$AppDatabase, $OutboxEntriesTable, OutboxRow>,
      ),
      OutboxRow,
      PrefetchHooks Function()
    >;
typedef $$PreferencesTableCreateCompanionBuilder =
    PreferencesCompanion Function({
      required String key,
      required String value,
      Value<int> rowid,
    });
typedef $$PreferencesTableUpdateCompanionBuilder =
    PreferencesCompanion Function({
      Value<String> key,
      Value<String> value,
      Value<int> rowid,
    });

class $$PreferencesTableFilterComposer
    extends Composer<_$AppDatabase, $PreferencesTable> {
  $$PreferencesTableFilterComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  ColumnFilters<String> get key => $composableBuilder(
    column: $table.key,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get value => $composableBuilder(
    column: $table.value,
    builder: (column) => ColumnFilters(column),
  );
}

class $$PreferencesTableOrderingComposer
    extends Composer<_$AppDatabase, $PreferencesTable> {
  $$PreferencesTableOrderingComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  ColumnOrderings<String> get key => $composableBuilder(
    column: $table.key,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get value => $composableBuilder(
    column: $table.value,
    builder: (column) => ColumnOrderings(column),
  );
}

class $$PreferencesTableAnnotationComposer
    extends Composer<_$AppDatabase, $PreferencesTable> {
  $$PreferencesTableAnnotationComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  GeneratedColumn<String> get key =>
      $composableBuilder(column: $table.key, builder: (column) => column);

  GeneratedColumn<String> get value =>
      $composableBuilder(column: $table.value, builder: (column) => column);
}

class $$PreferencesTableTableManager
    extends
        RootTableManager<
          _$AppDatabase,
          $PreferencesTable,
          PreferenceRow,
          $$PreferencesTableFilterComposer,
          $$PreferencesTableOrderingComposer,
          $$PreferencesTableAnnotationComposer,
          $$PreferencesTableCreateCompanionBuilder,
          $$PreferencesTableUpdateCompanionBuilder,
          (
            PreferenceRow,
            BaseReferences<_$AppDatabase, $PreferencesTable, PreferenceRow>,
          ),
          PreferenceRow,
          PrefetchHooks Function()
        > {
  $$PreferencesTableTableManager(_$AppDatabase db, $PreferencesTable table)
    : super(
        TableManagerState(
          db: db,
          table: table,
          createFilteringComposer: () =>
              $$PreferencesTableFilterComposer($db: db, $table: table),
          createOrderingComposer: () =>
              $$PreferencesTableOrderingComposer($db: db, $table: table),
          createComputedFieldComposer: () =>
              $$PreferencesTableAnnotationComposer($db: db, $table: table),
          updateCompanionCallback: ({
            Value<String> key = const Value.absent(),
            Value<String> value = const Value.absent(),
            Value<int> rowid = const Value.absent(),
          }) => PreferencesCompanion(key: key, value: value, rowid: rowid),
          createCompanionCallback:
              ({
                required String key,
                required String value,
                Value<int> rowid = const Value.absent(),
              }) => PreferencesCompanion.insert(
                key: key,
                value: value,
                rowid: rowid,
              ),
          withReferenceMapper: (p0) => p0
              .map((e) => (e.readTable(table), BaseReferences(db, table, e)))
              .toList(),
          prefetchHooksCallback: null,
        ),
      );
}

typedef $$PreferencesTableProcessedTableManager =
    ProcessedTableManager<
      _$AppDatabase,
      $PreferencesTable,
      PreferenceRow,
      $$PreferencesTableFilterComposer,
      $$PreferencesTableOrderingComposer,
      $$PreferencesTableAnnotationComposer,
      $$PreferencesTableCreateCompanionBuilder,
      $$PreferencesTableUpdateCompanionBuilder,
      (
        PreferenceRow,
        BaseReferences<_$AppDatabase, $PreferencesTable, PreferenceRow>,
      ),
      PreferenceRow,
      PrefetchHooks Function()
    >;

class $AppDatabaseManager {
  final _$AppDatabase _db;
  $AppDatabaseManager(this._db);
  $$SyncCursorsTableTableManager get syncCursors =>
      $$SyncCursorsTableTableManager(_db, _db.syncCursors);
  $$SyncedFilesTableTableManager get syncedFiles =>
      $$SyncedFilesTableTableManager(_db, _db.syncedFiles);
  $$SyncBindingsTableTableManager get syncBindings =>
      $$SyncBindingsTableTableManager(_db, _db.syncBindings);
  $$CachedGroupsTableTableManager get cachedGroups =>
      $$CachedGroupsTableTableManager(_db, _db.cachedGroups);
  $$CachedEventsTableTableManager get cachedEvents =>
      $$CachedEventsTableTableManager(_db, _db.cachedEvents);
  $$OutboxEntriesTableTableManager get outboxEntries =>
      $$OutboxEntriesTableTableManager(_db, _db.outboxEntries);
  $$PreferencesTableTableManager get preferences =>
      $$PreferencesTableTableManager(_db, _db.preferences);
}
