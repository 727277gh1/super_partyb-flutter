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
  late final $PreferencesTable preferences = $PreferencesTable(this);
  @override
  Iterable<TableInfo<Table, Object?>> get allTables =>
      allSchemaEntities.whereType<TableInfo<Table, Object?>>();
  @override
  List<DatabaseSchemaEntity> get allSchemaEntities => [
    syncCursors,
    syncedFiles,
    syncBindings,
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
  $$PreferencesTableTableManager get preferences =>
      $$PreferencesTableTableManager(_db, _db.preferences);
}
