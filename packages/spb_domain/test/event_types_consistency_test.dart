import 'dart:io';
import 'dart:isolate';

import 'package:spb_models/spb_models.dart';
import 'package:test/test.dart';

/// `EventTypes.timelineVisible` 与 `EventReducer` 的 case 分支一致性守卫。
///
/// ## 这个测试防的是什么
///
/// 本仓库有过一次真实的缺陷形态：常量集合（`EventTypes.timelineVisible`）说
/// 某个事件「应渲染进时间线」，而归约器的 `switch` 里**没有**对应分支，于是
/// 事件落到 `default:` 被静默丢弃。`goal_gate_stopped` 正是这个形态——集合里
/// 有它（`event_types.dart` 的 `timelineVisible`），实现里没有 case。
///
/// 这类漂移为什么**不会被现有测试发现**：
///
/// - 集合本身是 `const Set<String>`，改它不影响任何类型；
/// - 归约器的 `switch` 是**字符串** switch（`case EventTypes.xxx:` 是编译期常量
///   表达式），漏一个分支不产生编译错误，`default:` 兜住一切；
/// - 各事件的单测只覆盖「已实现的那几个」，漏掉的那个没有任何用例指向它。
///
/// 更隐蔽的是 `ChatEvent.isTimelineVisible`（`chat_event.dart`）——它是集合的
/// 唯一消费者，而**生产代码从不调用它**（归约器直接 `switch (ev.eventType)`），
/// 只有测试在用。于是「集合与实现」之间没有任何机制强制一致。
///
/// ## 为什么读源文件而不是用反射
///
/// Dart 没有运行时反射可用（`dart:mirrors` 在 AOT 下不可用，且本包是纯 Dart）。
/// 故本测试直接读 `lib/src/event_reducer.dart` 的源码文本，提取全部
/// `case EventTypes.<identifier>:` 的标识符。
///
/// ## 为什么用「蛇形 → 驼峰」推导而不是解析 event_types.dart
///
/// 解析两个文件的常量声明表会引入更多假设（声明格式、多行、注释）。而
/// `EventTypes` 的标识符与线值之间的命名约定是**机械且全仓一致**的
/// （`goal_gate_stopped` ↔ `goalGateStopped`），照它推导只需一处约定，
/// 且一旦某天出现不符合约定的新常量，本测试会**明确失败**并提示——这正是
/// 我们想要的（那时应改约定或显式登记例外，而不是让守卫静默失效）。
void main() {
  /// 归约器源码路径。`dart test` 的工作目录是包根（`packages/spb_domain`），
  /// 与 CI 中 `(cd packages/spb_domain && dart test)` 一致。
  final reducerPath = File('lib/src/event_reducer.dart');

  /// 从归约器源码中提取全部 `case EventTypes.<id>:` 的标识符。
  Set<String> extractCaseIdentifiers(String source) {
    final re = RegExp(r'case\s+EventTypes\.([A-Za-z0-9_]+)\s*:');
    return {for (final m in re.allMatches(source)) m.group(1)!};
  }

  /// `goal_gate_stopped` → `goalGateStopped`。
  String toCamel(String snake) {
    final parts = snake.split('_');
    return parts.first +
        parts
            .skip(1)
            .map((p) => p.isEmpty ? p : p[0].toUpperCase() + p.substring(1))
            .join();
  }

  test('归约器源码可读（守卫本身不能静默失效）', () {
    expect(
      reducerPath.existsSync(),
      isTrue,
      reason: '找不到 ${reducerPath.path}：本测试必须在 packages/spb_domain 下运行',
    );
  });

  test('timelineVisible 非空（守卫不能空转通过）', () {
    expect(
      EventTypes.timelineVisible,
      isNotEmpty,
      reason: '集合为空会让下面的子集断言无条件成立，守卫就失去意义',
    );
  });

  test('timelineVisible 的每个成员在归约器里都有显式 case', () {
    final source = reducerPath.readAsStringSync();
    final cases = extractCaseIdentifiers(source);

    final missing = <String>[];
    for (final wire in EventTypes.timelineVisible) {
      if (!cases.contains(toCamel(wire))) missing.add(wire);
    }

    expect(
      missing,
      isEmpty,
      reason:
          '以下事件声明为「应渲染进时间线」，但 EventReducer 没有对应 case，'
          '会落到 default: 分支被静默丢弃：$missing\n'
          '（修复：在 lib/src/event_reducer.dart 补 case，或把它们从 '
          'EventTypes.timelineVisible 移除——两者必须一致）',
    );
  });

  test('每个 case 标识符都对应一个已声明的常量（防拼写错误）', () async {
    final source = reducerPath.readAsStringSync();
    final cases = extractCaseIdentifiers(source);

    // 正向校验：每个 case 标识符都必须是 `EventTypes` 里真实声明的常量。
    //
    // ⚠️ 不能拿 `EventTypes.all` 当基准：`all` 刻意**不含** `agent.file.*`
    // 一族（见 event_types.dart 里 `all` 的注释：那一族走前缀匹配而非枚举），
    // 而归约器确实 switch 了 `agentFileCreated/Modified/Deleted`。用 `all`
    // 当基准会把三个正确分支误报为「未声明」。故直接解析常量声明表。
    final eventTypesUri = await Isolate.resolvePackageUri(
      Uri.parse('package:spb_models/src/event_types.dart'),
    );
    expect(
      eventTypesUri,
      isNotNull,
      reason: '无法解析 event_types.dart 的包 URI（守卫不能静默失效）',
    );
    final declarations = File.fromUri(eventTypesUri!)
        .readAsStringSync()
        .split('\n')
        .map(
          (line) =>
              RegExp(r"^\s*static const ([A-Za-z0-9_]+)\s*=\s*'")
                  .firstMatch(line)
                  ?.group(1),
        )
        .whereType<String>()
        .toSet();

    expect(
      declarations,
      isNotEmpty,
      reason: '未能从 event_types.dart 解析出任何常量声明，守卫会空转通过',
    );

    final unknown = cases.where((c) => !declarations.contains(c)).toList();

    expect(
      unknown,
      isEmpty,
      reason: '归约器 switch 了 EventTypes 未声明的事件标识符：$unknown',
    );
  });
}
