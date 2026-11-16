import 'dart:convert';
import 'dart:io';

import 'package:spb_domain/spb_domain.dart';
import 'package:spb_models/spb_models.dart';
import 'package:test/test.dart';

/// 错误码闭集（[ErrorCodes]）与服务端 vendored 清单的对拍。
///
/// ## 这组用例守的是什么
///
/// `error` 事件的 `code` 闭集真源在**服务端**（`super_partyb` 的
/// `chatbus.ErrorCodes()` → `apps/go-api/docs/error-codes.json`，由
/// `TestErrorCodesJSON` 生成）。客户端是镜像，镜像漂移的两种形态都不是编译期
/// 错误，而是用户可见的错：
///
/// | 漂移 | 后果 |
/// |---|---|
/// | 服务端新增 code，客户端没跟上 | 新错误落进 fail-open：无分类徽标、`retryable` 按旧默认（可能白给「重发」）|
/// | 客户端多了服务端没有的 code | 说明客户端在**猜语义**（服务端从不发 → 那行分支永远死）|
/// | `retryable` 两边不一致 | 用户看到「重发」按钮，按下去必然再撞同一面墙（OOM / internal_error 正是如此）|
///
/// 故这里断言**集合相等 + 顺序相等 + 逐条 `retryable` 相等**。顺序也断言，是因为
/// 顺序不同的 diff 无法审查（到底加了一个 code 还是全部重排？）。
///
/// ## 为什么读的是 vendored fixture 而不是服务端文件
///
/// 本仓库 CI 在 GitHub Actions，到不了 `git.atjog.com`（AGENTS.md §8）。
/// 副本由 `tools/sync_error_codes.sh` 刷新，随 PR 提交——CI 只读仓库内文件。
void main() {
  List<Map<String, dynamic>> loadServerCodes() {
    // 两种 cwd 都容忍：CI 在包目录下跑 `dart test`（AGENTS.md §2），
    // 而从仓库根手跑单文件时 cwd 是根。
    for (final path in [
      'test/fixtures/error_codes.json',
      'packages/spb_domain/test/fixtures/error_codes.json',
    ]) {
      final file = File(path);
      if (!file.existsSync()) continue;
      final raw = jsonDecode(file.readAsStringSync());
      if (raw is! List) {
        throw StateError('$path 顶层应为数组，实际是 ${raw.runtimeType}');
      }
      return raw.cast<Map<String, dynamic>>();
    }
    throw StateError(
      '找不到 error_codes.json：先跑 `bash tools/sync_error_codes.sh`',
    );
  }

  group('error code 闭集对拍（服务端 docs/error-codes.json）', () {
    final server = loadServerCodes();

    test('code 集合与顺序和客户端闭集逐条相等', () {
      expect(
        ErrorCodes.all,
        server.map((row) => row['code'] as String).toList(),
        reason: '闭集漂移：改服务端清单后跑 tools/sync_error_codes.sh 并同步 error_code.dart',
      );
    });

    test('客户端闭集没有重复项', () {
      expect(ErrorCodes.all.toSet().length, ErrorCodes.all.length);
    });

    test('retryable 与服务端 chatbus.Retryable 逐条一致', () {
      for (final row in server) {
        final code = row['code'] as String;
        expect(
          ErrorCodes.traits(code).retryable,
          row['retryable'],
          reason: 'code=$code 的 retryable 与服务端不一致（真源 chatbus.Retryable）',
        );
      }
    });

    test('每个已知 code 都有分类徽标与图标（未知 code 才走兜底）', () {
      for (final code in ErrorCodes.all) {
        final traits = ErrorCodes.traits(code);
        expect(ErrorCodes.isKnown(code), isTrue, reason: code);
        expect(traits.label, isNotNull, reason: code);
        expect(traits.label, isNotEmpty, reason: code);
        expect(
          traits.icon,
          isNot(ErrorCodeIcon.generic),
          reason: 'code=$code 落到 generic 会让它和「未知 code」长得一样',
        );
      }
    });

    test('客户端不自带正文文案（文案真源在服务端的 message）', () {
      // 守的是「不抄一份必然漂移的文案」这条：traits 只有分类徽标，
      // 徽标文本必须短于一句完整话术（服务端 default_message 都是十几字的句子）。
      for (final row in server) {
        final traits = ErrorCodes.traits(row['code'] as String);
        final message = row['default_message'] as String;
        expect(traits.label, isNot(message), reason: '不要抄 default_message');
        expect(
          (traits.label ?? '').length < message.length,
          isTrue,
          reason: 'label 应是短徽标（如「内存不足」），不是一句完整话术',
        );
      }
    });
  });

  group('生产实测载荷（2026-11-16，重启回填）', () {
    // 现场原文（`chat_events.payload_json`，`turn_interrupted`）：
    //   {"code":"turn_interrupted","content":"本轮被意外中断（服务重启或进程退出），
    //    已标记失败。可重新发送消息重试。","backfilled":true,"turn_status":"failed"}
    //
    // 两个要点：① 该轮**没有 `message`**，只有过渡期的 `content` → 正文必须靠
    // content 兜底（否则用户看到空正文的红卡）；② 它是 `Retryable` 的 true，
    // 「重发」该给（这正是服务端文案在建议的动作）。
    const payload = {
      'code': 'turn_interrupted',
      'content': '本轮被意外中断（服务重启或进程退出），已标记失败。可重新发送消息重试。',
      'backfilled': true,
      'turn_status': 'failed',
    };

    test('turn_interrupted 在闭集内且可重发', () {
      expect(ErrorCodes.isKnown(ErrorCodes.turnInterrupted), isTrue);
      final traits = ErrorCodes.traits(ErrorCodes.turnInterrupted);
      expect(traits.retryable, isTrue, reason: '与 chatbus.Retryable 一致');
      expect(traits.label, '本轮被中断');
      expect(traits.icon, ErrorCodeIcon.interrupted);
    });

    test('只有 content 的老形状也能出正文（不依赖 message）', () {
      // `errorMessage` 的兜底顺序：message → content → error → detail。
      final event = ChatEvent(
        eventId: 'e1',
        userId: 'usr_1',
        groupId: 'grp_1',
        turnId: 'turn_1',
        eventType: EventTypes.error,
        seq: 1,
        source: 'agent',
        createdAt: DateTime.utc(2026, 11, 16, 14, 21, 4),
        payload: payload,
      );
      expect(event.errorCode, 'turn_interrupted');
      expect(event.errorMessage, payload['content']);
      expect(event.errorDetail, isNull, reason: '回填事件没有 detail');
    });
  });

  group('fail-open（未知 / 缺失 code）', () {
    test('null / 空串 / 闭集外的值都落到 failOpen', () {
      for (final code in [null, '', 'brand_new_code']) {
        expect(
          ErrorCodes.traits(code),
          ErrorCodeTraits.failOpen,
          reason: '$code',
        );
        expect(ErrorCodes.isKnown(code), isFalse, reason: '$code');
      }
    });

    test('failOpen 保持今天的行为：可重发、不猜分类、通用图标', () {
      // 历史事件（#182 之前只有 content）走这一格；把「重发」收掉是**负向**
      // 行为变化，而多渲染一次的代价只是「按了也没用」。
      expect(ErrorCodeTraits.failOpen.retryable, isTrue);
      expect(ErrorCodeTraits.failOpen.label, isNull);
      expect(ErrorCodeTraits.failOpen.icon, ErrorCodeIcon.generic);
    });
  });
}
