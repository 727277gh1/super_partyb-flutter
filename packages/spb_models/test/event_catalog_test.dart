import 'dart:convert';
import 'dart:io';

import 'package:spb_models/spb_models.dart';
import 'package:test/test.dart';

/// 事件契约目录（`super_partyb/apps/go-api/docs/event-catalog.json`）的 parity 守卫。
///
/// ## 这个文件防的是什么（issue #116）
///
/// 服务端有一份机器可读的目录（62 entries / 60 类型 / 7 类别 / 5 动作），声明了每个
/// `(type, form)` 的 `timeline / persist / broadcast / required / optional`。本仓在
/// #116 之前**完全没有对接**：服务端新增一个时间线事件 → 本仓没有归约分支 → 落到
/// `default:` → **静默丢帧**，所有测试照常绿，用户只看到「回答少了点什么」。
///
/// 所以这里把三条事实钉死：
///
/// 1. **类别闭集**：`EventCategory.all` 与服务端目录逐条、按序相等；
/// 2. **时间线覆盖**：目录里每个 `timeline: true` 的类型，`ChatEvent.isTimelineVisible`
///    都为真（走**生产**判定，不是另写一份）；
/// 3. **控制类闭环**：目录里每个 `timeline: false` 的类型，要么本仓认识（`EventTypes.all`），
///    要么在 `EventTypes.diagnosticOnly` 里登记过——不允许「既没实现也没登记」的灰区。
///
/// ## 为什么读 vendored fixture 而不是服务端文件
///
/// 本仓库 CI 在 GitHub Actions，到不了 `<gitea-host>`（AGENTS.md §8）。副本由
/// `tools/sync_event_catalog.sh` 刷新并随 PR 提交（流程见 `fixtures/README.md`）。
///
/// ## 为什么不用 `sha256` 锁死
///
/// 试过，不可行：CI 拉不到真源，`sha256` 只能锁「上次同步时那份」，同步一次就要改一次
/// 常量，收益为零。真正有价值的断言是**语义等价**（类别/时间线/控制类），那三条
/// 恰好就是本仓实际消费的部分。
void main() {
  Map<String, dynamic> loadCatalog() {
    // 两种 cwd 都容忍：CI 在包目录下跑 `dart test`（AGENTS.md §2），
    // 而从仓库根手跑单文件时 cwd 是根。
    for (final path in [
      'fixtures/event-catalog.json',
      'packages/spb_models/fixtures/event-catalog.json',
    ]) {
      final file = File(path);
      if (!file.existsSync()) continue;
      final raw = jsonDecode(file.readAsStringSync());
      if (raw is! Map<String, dynamic>) {
        throw StateError('$path 顶层应为对象，实际是 ${raw.runtimeType}');
      }
      return raw;
    }
    throw StateError(
      '找不到 event-catalog.json：先跑 `bash tools/sync_event_catalog.sh`',
    );
  }

  final catalog = loadCatalog();
  final entries = (catalog['entries'] as List).cast<Map<String, dynamic>>();
  final actions = (catalog['actions'] as List).cast<Map<String, dynamic>>();
  final envelope = catalog['envelope'] as Map<String, dynamic>;
  final envelopeKeys = (envelope['keys'] as List).cast<String>();
  final envelopeDefaults = (envelope['default'] as List).cast<String>();

  /// 造一条最小事件，只为了走生产判定 `ChatEvent.isTimelineVisible`。
  ChatEvent event(String type) => ChatEvent(
    eventId: 'e',
    userId: 'u',
    groupId: 'g',
    turnId: 't',
    eventType: type,
    seq: 1,
    source: 'test',
    createdAt: DateTime.utc(2026, 1, 1),
  );

  group('目录自身结构（服务端产物不能是坏的）', () {
    test('schema_version 是已知版本（结构变更时必须同步改本仓）', () {
      expect(
        catalog['schema_version'],
        1,
        reason: 'schema 变了意味着字段名/必填段变了，本仓的读取假设需要重审',
      );
    });

    test('entries 非空，且 (type, form) 唯一', () {
      expect(entries, isNotEmpty, reason: '空目录会让下面所有断言空转通过');
      final seen = <String>{};
      for (final e in entries) {
        final key = '${e['type']}|${e['form']}';
        expect(
          seen.add(key),
          isTrue,
          reason: '$key 重复：同一形态不应出现两次（同一类型可有 durable/delta 两形态）',
        );
      }
    });

    test('信封闭集自洽：default ⊆ keys，每条 entry 的 envelope ⊆ keys', () {
      expect(
        envelopeDefaults.toSet().difference(envelopeKeys.toSet()),
        isEmpty,
      );
      for (final e in entries) {
        final env = (e['envelope'] as List).cast<String>().toSet();
        expect(
          env.difference(envelopeKeys.toSet()),
          isEmpty,
          reason: '${e['type']} 声明了信封外的键',
        );
      }
    });

    test('required 与 optional 不相交；不落库的类型必须广播', () {
      for (final e in entries) {
        final required = (e['required'] as List).cast<String>().toSet();
        final optional = (e['optional'] as List).cast<String>().toSet();
        expect(
          required.intersection(optional),
          isEmpty,
          reason: '${e['type']}: 同一个键不能既必填又可选',
        );
        if (e['persist'] == false) {
          expect(
            e['broadcast'],
            isTrue,
            reason: '${e['type']}: 不落库又不广播 = 永远到不了任何消费者',
          );
        }
      }
    });
  });

  group('类别闭集对拍', () {
    test('EventCategory.all 与服务端 categories 集合 + 顺序相等', () {
      expect(
        EventCategory.all,
        (catalog['categories'] as List).cast<String>(),
        reason:
            '类别漂移：服务端加/改类别后跑 tools/sync_event_catalog.sh，'
            '并同步 lib/src/event_category.dart',
      );
    });

    test('每条 entry 的 category 都在闭集内', () {
      final known = EventCategory.all.toSet();
      for (final e in entries) {
        expect(
          known.contains(e['category']),
          isTrue,
          reason: '${e['type']} 的 category=${e['category']} 不在闭集内',
        );
      }
    });
  });

  group('时间线覆盖（本票的核心断言）', () {
    test('目录里每个 timeline:true 的类型都能进时间线渲染', () {
      final timelineTypes = entries
          .where((e) => e['timeline'] == true)
          .map((e) => e['type'] as String)
          .toSet();

      // 目录里没有 timeline 事件 = 断言空转，守卫失效。
      expect(timelineTypes, isNotEmpty);

      final missing = <String>[];
      for (final type in timelineTypes) {
        if (!event(type).isTimelineVisible) missing.add(type);
      }

      expect(
        missing,
        isEmpty,
        reason:
            '以下类型服务端声明「进时间线」，但本仓 isTimelineVisible 判定为假，'
            '会落到归约器 default 分支被静默丢弃：$missing\n'
            '（修复：在 EventTypes.timelineVisible 或前缀规则里登记，并补归约 case）',
      );
    });

    test('未知类型的可见性判据：控制类不渲染、真正的新类型才渲染', () {
      // 「服务端发了新时间线事件」与「服务端发了新的控制事件」在运行时无法区分，
      // 判据是三条件的合取（见 EventTypes.shouldSurfaceUnknown）。
      expect(
        EventTypes.shouldSurfaceUnknown(
          eventType: 'brand_new_timeline_event',
          transient: false,
          diagnostic: false,
        ),
        isTrue,
        reason: '未知 + 落库 + 非诊断 ⇒ 应当渲染成「未知事件」一行而不是静默丢弃',
      );
      // 现存的控制类（既有实现、无渲染分支）不得因此冒泡成噪声。
      expect(
        EventTypes.shouldSurfaceUnknown(
          eventType: 'executor_startup',
          transient: false,
          diagnostic: false,
        ),
        isFalse,
        reason: 'diagnosticOnly 里有登记的控制事件不能被当成「未知时间线事件」',
      );
      // 增量/心跳类永远不进时间线。
      expect(
        EventTypes.shouldSurfaceUnknown(
          eventType: 'brand_new_delta',
          transient: true,
          diagnostic: false,
        ),
        isFalse,
      );
      // 服务端自己标了诊断的，尊重服务端判定。
      expect(
        EventTypes.shouldSurfaceUnknown(
          eventType: 'brand_new_diagnostic',
          transient: false,
          diagnostic: true,
        ),
        isFalse,
      );
    });
  });

  group('控制类闭环（不允许「既没实现也没登记」的灰区）', () {
    test('timeline:false 的类型，要么本仓认识，要么在 diagnosticOnly 里', () {
      final unaccounted = <String>[];
      for (final e in entries) {
        if (e['timeline'] == true) continue;
        final type = e['type'] as String;
        final known = EventTypes.all.contains(type);
        final registered = EventTypes.diagnosticOnly.contains(type);
        // 增量帧不是「事件类型」而是一个形态：它们靠 isIncremental 处理。
        final delta = e['form'] == 'delta';
        if (!known && !registered && !delta) unaccounted.add(type);
      }
      expect(
        unaccounted,
        isEmpty,
        reason:
            '以下类型既不进时间线、本仓也不认识、也没登记进 diagnosticOnly：'
            '$unaccounted\n（修复：实现它，或登记进 EventTypes.diagnosticOnly）',
      );
    });

    test('diagnosticOnly 不装「本仓其实认识」或「服务端根本不发」的类型', () {
      final known = unaccountedKnown();
      expect(
        known,
        isEmpty,
        reason: 'diagnosticOnly 里这些类型已经是本仓认识的（应在 all 里而不是这里）：$known',
      );

      final serverTypes = entries.map((e) => e['type'] as String).toSet();
      final invented = EventTypes.diagnosticOnly.difference(serverTypes);
      expect(
        invented,
        isEmpty,
        reason: 'diagnosticOnly 里这些类型服务端目录根本没有：$invented（删掉或改名）',
      );
    });
  });

  group('动作表（用户动作 → 端点 / 幂等键 / 回执）', () {
    test('每个动作的 events 与 idempotent 都能落地', () {
      expect(actions, isNotEmpty);
      final serverTypes = entries.map((e) => e['type'] as String).toSet();
      for (final a in actions) {
        expect(a['action_id'], isA<String>());
        expect((a['action_id'] as String), isNotEmpty);
        expect(a['endpoint'], isA<String>());
        expect((a['endpoint'] as String).startsWith('POST '), isTrue);
        // 动作触发的入口事件必须能在这份目录里找到。
        final events = (a['events'] as List).cast<String>();
        expect(events, isNotEmpty);
        expect(
          events.toSet().difference(serverTypes),
          isEmpty,
          reason: '${a['action_id']} 的入口事件不在目录里',
        );
        // 幂等键：只需非空。**不**断言「必须是 payload 或信封键」——服务端有 2/5 的
        // 动作用的是资源 id（`confirmation_id` / `suggestion_id`），它们不在 payload 里，
        // 断言成 payload∪envelope 会当场假红（#116 票面写错过这一点）。
        expect(
          (a['idempotent'] as String),
          isNotEmpty,
          reason: '${a['action_id']} 没有幂等键：重试会重复执行',
        );
        expect(a['ack_event'], isA<String>());
      }
    });
  });
}

/// `diagnosticOnly` 里那些其实已在 `EventTypes.all` 里的（应当为空）。
Set<String> unaccountedKnown() =>
    EventTypes.diagnosticOnly.intersection(EventTypes.all);
