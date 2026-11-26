/// 只读取文档快照，不执行表达式或修改服务端状态。
Object? readSpecState(Object? state, String pointer) {
  if (pointer.isEmpty || pointer == '/') return state;
  if (!pointer.startsWith('/')) return null;
  Object? value = state;
  for (final raw in pointer.substring(1).split('/')) {
    final key = raw.replaceAll('~1', '/').replaceAll('~0', '~');
    if (value is Map<Object?, Object?>) {
      value = value[key];
    } else if (value is List<Object?>) {
      final index = int.tryParse(key);
      if (index == null || index < 0 || index >= value.length) return null;
      value = value[index];
    } else {
      return null;
    }
  }
  return value;
}

Object? resolveSpecValue(Object? value, Object? state, {int depth = 0}) {
  // 外部 JSON 的深层 props 也需要限深，不能只保护 children 引用。
  if (depth > 32) return null;
  if (value is List<Object?>) {
    return [
      for (final item in value) resolveSpecValue(item, state, depth: depth + 1),
    ];
  }
  if (value is! Map<Object?, Object?>) return value;
  for (final key in [r'$state', r'$bindState']) {
    final path = value[key];
    if (path is String && path.startsWith('/')) {
      return readSpecState(state, path);
    }
  }
  return <String, Object?>{
    for (final entry in value.entries)
      if (entry.key is String)
        entry.key! as String: resolveSpecValue(
          entry.value,
          state,
          depth: depth + 1,
        ),
  };
}

bool _truthy(Object? value) => switch (value) {
  null => false,
  bool v => v,
  num v => v != 0 && !v.isNaN,
  String v => v.isNotEmpty,
  _ => true,
};

/// 与 Web 的静态可见性条件一致；不运行 watch 或 setState。
bool specValueVisible(Object? condition, Object? state) {
  if (condition == null) return true;
  if (condition is bool) return condition;
  final value = resolveSpecValue(condition, state);
  if (condition is Map<Object?, Object?>) {
    if (condition.containsKey('eq') &&
        value != resolveSpecValue(condition['eq'], state)) {
      return false;
    }
    if (condition.containsKey('neq') &&
        value == resolveSpecValue(condition['neq'], state)) {
      return false;
    }
    if (condition.containsKey('truthy')) {
      return _truthy(value) == _truthy(condition['truthy']);
    }
    if (condition.containsKey('exists')) {
      return (value != null) == _truthy(condition['exists']);
    }
  }
  if (condition is Map<Object?, Object?> &&
      (condition.containsKey('eq') || condition.containsKey('neq'))) {
    return true;
  }
  return _truthy(value);
}
