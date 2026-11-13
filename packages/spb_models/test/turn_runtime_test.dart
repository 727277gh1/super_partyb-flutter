import 'package:spb_models/spb_models.dart';
import 'package:test/test.dart';

/// [TurnRuntime] 的解析与阈值防御测试。
///
/// ## 这个测试防的是什么
///
/// 这个模型的唯一用途是给「超时兜底」提供一个阈值。阈值算错的后果是不对称的：
///
/// - **算大**：`done` 丢失后 UI 多卡一会儿（可接受）；
/// - **算小**：正在跑的长 turn 被提前判成静止，用户以为已结束（误导）；
/// - **算成 0**：所有正在跑的 turn 瞬间判成静止（比不修更糟）。
///
/// 故「0 / 负数 → 不可用」与「离谱值 → 截到 24h」这两条必须有可执行的回归。
void main() {
  Map<String, dynamic> shape({
    Object? request = 600,
    Object? inactivity = 0,
    Object? client = 600,
    Object? feedbackTTL,
  }) => {
    'request_timeout_seconds': request,
    'inactivity_timeout_seconds': inactivity,
    'client_turn_timeout_seconds': client,
    if (feedbackTTL != null) 'attribution_feedback_ttl_seconds': feedbackTTL,
  };

  group('TurnRuntime.fromJson', () {
    test('三字段按契约键名解析', () {
      final rt = TurnRuntime.fromJson(shape());

      expect(rt.requestTimeoutSeconds, 600);
      expect(rt.inactivityTimeoutSeconds, 0);
      expect(rt.clientTurnTimeoutSeconds, 600);
    });

    test('JSON 的 double（600.0）也能解析', () {
      final rt = TurnRuntime.fromJson(
        shape(request: 600.0, inactivity: 30.0, client: 30.0),
      );

      expect(rt.requestTimeoutSeconds, 600);
      expect(rt.clientTurnTimeoutSeconds, 30);
    });

    test('字符串数字能解析（服务端历史上有过 string 载荷）', () {
      final rt = TurnRuntime.fromJson(shape(client: '45'));

      expect(rt.clientTurnTimeoutSeconds, 45);
    });

    test('字段缺失 / 类型异常一律归 0，不抛异常', () {
      final rt = TurnRuntime.fromJson({
        'request_timeout_seconds': null,
        'inactivity_timeout_seconds': 'abc',
        // client 键整个缺失
      });

      expect(rt.requestTimeoutSeconds, 0);
      expect(rt.inactivityTimeoutSeconds, 0);
      expect(rt.clientTurnTimeoutSeconds, 0);
    });
  });

  group('clientTurnTimeout（阈值防御）', () {
    test('正常值原样转成 Duration', () {
      final rt = TurnRuntime.fromJson(shape(client: 600));

      expect(rt.clientTurnTimeout, const Duration(minutes: 10));
    });

    test('0 → null（不可用），不是 Duration.zero', () {
      // 服务端 inactivity_timeout_seconds=0 的语义是「关闭该看门狗」，
      // 客户端若当成「零秒超时」会把所有正在跑的 turn 瞬间判成静止。
      final rt = TurnRuntime.fromJson(shape(request: 0, client: 0));

      expect(rt.clientTurnTimeout, isNull);
      expect(rt.clientTurnTimeout, isNot(Duration.zero));
    });

    test('负数 → null', () {
      final rt = TurnRuntime.fromJson(shape(client: -5));

      expect(rt.clientTurnTimeout, isNull);
    });

    test('离谱大值截到 24h（配置写错时兜底不能永不触发）', () {
      final rt = TurnRuntime.fromJson(shape(client: 999999999));

      expect(rt.clientTurnTimeout, const Duration(hours: 24));
    });

    test('恰好 24h 不截断', () {
      final rt = TurnRuntime.fromJson(shape(client: 24 * 60 * 60));

      expect(rt.clientTurnTimeout, const Duration(hours: 24));
    });
  });

  group('effectiveClientTurnTimeout', () {
    test('可用时等于 clientTurnTimeout', () {
      final rt = TurnRuntime.fromJson(shape(client: 42));

      expect(rt.effectiveClientTurnTimeout, const Duration(seconds: 42));
    });

    test('不可用时退化为 fallback（与 Go env 默认值同量级）', () {
      final rt = TurnRuntime.fromJson(shape(client: 0));

      expect(rt.effectiveClientTurnTimeout, TurnRuntime.fallback);
      expect(TurnRuntime.fallback, const Duration(minutes: 5));
    });
  });

  group('attributionFeedbackTTL（归属反馈有效期）', () {
    test('解析服务端下发值', () {
      final rt = TurnRuntime.fromJson(shape(feedbackTTL: 86400));

      expect(rt.attributionFeedbackTTLSeconds, 86400);
      expect(rt.attributionFeedbackTTL, const Duration(hours: 24));
    });

    test('未下发（旧版后端）时为 null —— 不做失效判定', () {
      // 方向很重要：若把「未下发」当成 0 秒，所有卡片会一次性变灰，
      // 比不判定更糟（同 clientTurnTimeout 对 0 的取向）。
      final rt = TurnRuntime.fromJson(shape());

      expect(rt.attributionFeedbackTTLSeconds, 0);
      expect(rt.attributionFeedbackTTL, isNull);
    });

    test('0 / 负数同样视为未下发', () {
      expect(
        TurnRuntime.fromJson(shape(feedbackTTL: 0)).attributionFeedbackTTL,
        isNull,
      );
      expect(
        TurnRuntime.fromJson(shape(feedbackTTL: -5)).attributionFeedbackTTL,
        isNull,
      );
    });

    test('离谱大值截到 7 天（配置写错时不能变成永不过期）', () {
      final rt = TurnRuntime.fromJson(shape(feedbackTTL: 999999999));

      expect(rt.attributionFeedbackTTL, TurnRuntime.maxFeedbackTTL);
      expect(TurnRuntime.maxFeedbackTTL, const Duration(days: 7));
    });

    test('恰好 7 天不截断', () {
      final rt = TurnRuntime.fromJson(shape(feedbackTTL: 7 * 24 * 60 * 60));

      expect(rt.attributionFeedbackTTL, const Duration(days: 7));
    });

    test('字符串数字也可解析（与其它字段同一容错取向）', () {
      final rt = TurnRuntime.fromJson(shape(feedbackTTL: '3600'));

      expect(rt.attributionFeedbackTTL, const Duration(hours: 1));
    });
  });
}
