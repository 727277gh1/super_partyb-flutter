import 'package:test/test.dart';

import 'package:spb_models/spb_models.dart';

/// 通知模板白名单测试。
///
/// ## 真源与镜像的同步
///
/// 白名单的真源是 `apps/go-api/internal/notifications/store.go` 的
/// `KnownTemplate`。本类只是镜像，**两边必须同步**——漏一个 key，服务端
/// 会整体 400（不是忽略那一项），而客户端可能只看到「保存失败」。
///
/// 故这里把四个字面量**逐个写死**（而不是遍历 `all` 自证）：若有人改了
/// `all` 却改错字面量，遍历式断言会一起错过去。
void main() {
  test('白名单与 Go 侧 KnownTemplate 逐字对齐', () {
    expect(MiniappNotificationTemplates.notify, 'notify');
    expect(MiniappNotificationTemplates.workCompleted, 'work_completed');
    expect(MiniappNotificationTemplates.workFailed, 'work_failed');
    expect(
      MiniappNotificationTemplates.confirmationRequired,
      'confirmation_required',
    );
  });

  test('all 恰好包含四个 key，且主 key 在首位', () {
    expect(MiniappNotificationTemplates.all, hasLength(4));
    expect(
      MiniappNotificationTemplates.all.first,
      MiniappNotificationTemplates.notify,
      reason: 'notify 是唯一有生产者的 key，UI 展示顺序应把它放最前',
    );
    expect(
      MiniappNotificationTemplates.all.toSet(),
      hasLength(4),
      reason: '不能有重复项（重复会让 UI 渲染两个同 key 的开关）',
    );
  });

  test('isKnown 只放行白名单 key', () {
    for (final key in MiniappNotificationTemplates.all) {
      expect(MiniappNotificationTemplates.isKnown(key), isTrue);
    }
    expect(MiniappNotificationTemplates.isKnown('bogus'), isFalse);
    expect(MiniappNotificationTemplates.isKnown(''), isFalse);
    // 大小写敏感：服务端是精确匹配，客户端不能更宽松。
    expect(MiniappNotificationTemplates.isKnown('Notify'), isFalse);
  });

  test('订阅模型解析服务端的 snake_case 与整数额度', () {
    final sub = MiniappNotificationSubscription.fromJson(const {
      'user_id': 'u1',
      'template_key': 'notify',
      'remaining_quota': 3,
      'enabled': true,
      'updated_at': '2024-03-05T08:09:10Z',
    });

    expect(sub.templateKey, 'notify');
    expect(sub.remainingQuota, 3);
    expect(sub.enabled, isTrue);
    expect(sub.userId, 'u1');
    expect(sub.updatedAt, isNotNull);
  });

  test('缺字段时额度退化为 0、enabled 退化为 false（不抛）', () {
    final sub = MiniappNotificationSubscription.fromJson(const {});
    expect(sub.templateKey, '');
    expect(sub.remainingQuota, 0);
    expect(sub.enabled, isFalse);
  });
}
