import 'package:spb_api/spb_api.dart';
import 'package:spb_core/spb_core.dart';
import 'package:spb_features/spb_features.dart';
import 'package:flutter_test/flutter_test.dart';

/// 邮箱 magic link 登录编排的测试。
///
/// ## 这个测试防的是什么
///
/// 编排里的失败模式都是**静默**的：
/// - 服务端拒绝后没有 `consume()` 待验证请求 → 残留的 state 让下一次
///   登录回调被误判为「有进行中的登录」；
/// - 轮询没有超时/取消 → 登录页永远停在「请在邮件中确认」；
/// - 兑换用的 pkce 与发起时不是同一对 → 授权码换 token 必然失败，而错误
///   发生在用户看不见的一层；
/// - 未确认就兑换 → 409，但用户看到的是「登录失败」而不是「去点邮件」。
void main() {
  late _FakeClient client;
  late InMemoryPendingAuthStore store;

  setUp(() {
    client = _FakeClient();
    store = InMemoryPendingAuthStore();
  });

  /// 注入确定性 pkce，便于断言「发起与兑换用的是同一对」。
  PkcePair fixedPkce() =>
      PkcePair(verifier: 'v' * 64, challenge: OidcPkce.challengeFor('v' * 64));

  Future<String?> run({
    String email = 'user@example.com',
    Future<String?> Function(String code, PkcePair pkce)? onCode,
    Future<void> Function()? onSent,
    bool Function()? isActive,
    Duration timeout = const Duration(minutes: 10),
    Future<void> Function(Duration)? sleep,
  }) => magicLinkSignIn(
    client: client,
    store: store,
    email: email,
    onCode: onCode ?? (code, pkce) async => null,
    onSent: onSent,
    isActive: isActive,
    stateGenerator: () => 'state-1234567890',
    pkceGenerator: fixedPkce,
    pollInterval: const Duration(seconds: 1),
    pollMaxInterval: const Duration(seconds: 1),
    pollTimeout: timeout,
    sleep: sleep ?? (_) async {},
  );

  test('全链路：受理 → 轮询到 confirmed → 兑换 → 交给落盘点', () async {
    client.pollStates.addAll([
      MagicLinkPollState.pending,
      MagicLinkPollState.confirmed,
    ]);

    String? gotCode;
    PkcePair? gotPkce;
    var sent = 0;

    final error = await run(
      onSent: () async => sent++,
      onCode: (code, pkce) async {
        gotCode = code;
        gotPkce = pkce;
        return null;
      },
    );

    expect(error, isNull);
    expect(sent, 1, reason: 'onSent 应在邮件受理后触发一次');
    expect(gotCode, 'code-1');
    expect(client.requestedEmails, ['user@example.com']);
    // 兑换必须用发起时那一对 PKCE：challenge 对不上 verifier 就换不到 token。
    expect(gotPkce!.verifier, fixedPkce().verifier);
    expect(client.exchangedChallenge, fixedPkce().challenge);
    expect(client.exchangedState, 'state-1234567890');
  });

  test('受理阶段就失败（如限频）→ 返回服务端文案，并清掉待验证请求', () async {
    client.requestError = const AuthError('登录邮件发送过于频繁，请稍后再试');

    final error = await run();

    expect(error, contains('过于频繁'));
    expect(await store.consume(), isNull, reason: '失败必须清掉残留的 state');
    expect(client.pollStates, isEmpty, reason: '受理失败不该开始轮询');
  });

  test('链接过期 → 可读提示，且清掉待验证请求', () async {
    client.pollStates.add(MagicLinkPollState.expired);

    final error = await run();

    expect(error, contains('过期'));
    expect(await store.consume(), isNull);
  });

  test('一直 pending 到超时 → 提示重试（不能永远挂着）', () async {
    client.pollStates.addAll(List.filled(100, MagicLinkPollState.pending));

    final error = await run(timeout: const Duration(milliseconds: 30));

    expect(error, contains('超时'));
    expect(await store.consume(), isNull);
  });

  test('isActive 变 false 时立刻停止轮询（用户已离开登录页）', () async {
    client.pollStates.addAll(List.filled(100, MagicLinkPollState.pending));
    var calls = 0;

    final error = await run(isActive: () => calls++ == 0);

    expect(error, contains('取消'));
    // 第一次循环就返回 pending 并退出：不该把 10 分钟窗口跑满。
    expect(client.pollCalls, 1);
    expect(await store.consume(), isNull);
  });

  test('兑换失败（还没在邮件里确认）→ 透出服务端文案', () async {
    client.pollStates.add(MagicLinkPollState.confirmed);
    client.exchangeError = const AuthError('还没有在邮件里确认，请点开邮件中的链接并点击「确认登录」');

    final error = await run();

    expect(error, contains('确认登录'));
    expect(await store.consume(), isNull);
  });

  test('邮箱为空 / 明显不是邮箱时不发请求', () async {
    expect(await run(email: '   '), contains('请输入邮箱'));
    expect(await run(email: 'not-an-email'), contains('格式'));
    expect(client.requestedEmails, isEmpty);
  });

  test('邮箱两端空白被裁掉', () async {
    client.pollStates.add(MagicLinkPollState.confirmed);
    await run(email: '  user@example.com  ');
    expect(client.requestedEmails, ['user@example.com']);
  });

  test('轮询异常（网络抖动）不会被吞成「成功」', () async {
    client.pollError = const AuthError('无法连接认证服务，请检查网络后重试');
    expect(() => run(), throwsA(isA<AuthError>()));
  });
}

/// 假客户端：记录调用、按脚本返回轮询状态。
///
/// 继承真实类（而非实现接口）：[MagicLinkClient] 的构造参数是纯数据，
/// 覆盖三个方法即可，避免为测试引入一层接口（那会让生产代码多一层间接）。
class _FakeClient extends MagicLinkClient {
  _FakeClient()
    : super(
        issuer: Uri.parse('https://idp.example.com/idp'),
        clientId: 'client-1',
        redirectUri: 'partyb://oidc/callback',
      );

  final List<String> requestedEmails = [];
  final List<MagicLinkPollState> pollStates = [];

  AuthError? requestError;
  AuthError? exchangeError;
  AuthError? pollError;

  String? exchangedChallenge;
  String? exchangedState;
  int pollCalls = 0;

  @override
  Future<MagicLinkRequest> request(String email) async {
    requestedEmails.add(email);
    if (requestError != null) throw requestError!;
    return const MagicLinkRequest(requestId: 'req-1');
  }

  @override
  Future<MagicLinkPollState> poll(String requestId) async {
    pollCalls++;
    if (pollError != null) throw pollError!;
    if (pollStates.isEmpty) return MagicLinkPollState.pending;
    return pollStates.removeAt(0);
  }

  @override
  Future<String> exchange({
    required String requestId,
    required PkcePair pkce,
    required String state,
  }) async {
    if (exchangeError != null) throw exchangeError!;
    exchangedChallenge = pkce.challenge;
    exchangedState = state;
    return 'code-1';
  }
}
