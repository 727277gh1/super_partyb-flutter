import 'package:spb_models/spb_models.dart';
import 'package:test/test.dart';

/// `Agent` / `GroupSession` / `GroupAgentSwitchResult` 的契约测试。
///
/// ## 为什么这批模型此前零覆盖
///
/// 它们是 `GET /api/agents`、`GET /chat/groups/:gid/sessions`、
/// `POST .../sessions/switch` 的投影。三个形状**互不相同**：
///
/// | 端点 | 关键字段 |
/// |---|---|
/// | `/api/agents` | `group_name` / `content_md` / `provider_type` / `model_tier` |
/// | `/sessions` | `agent_name` / `agent_provider` / `session_id`（可空） |
/// | `/switch` | `new_agent_id` / `switched`（**不是** `agent_id`） |
///
/// 尤其 `switch` 的响应键是 `new_agent_id`——写成 `agent_id` 会得到空串，
/// 于是「切换成功」被误判成「切到了空 agent」。本文件按服务端样本钉住键名。
///
/// ## `provider_config` / `env` 是**不透明** Map
///
/// 服务端原样透传（可能含凭据引用），客户端**不解析**。测试只断言
/// 「是对象时保留、非对象归一成 null」，不深入内容——那是有意的不变量。
void main() {
  group('Agent（GET /api/agents 的 agentDTO）', () {
    /// `agentDTO` 的真实形状（`internal/server/agents.go`）。
    Map<String, dynamic> agentJson({
      Object? id = 'agt_1',
      Object? name = '小助手',
      Object? groupName = '默认分组',
      Object? contentMd = '# 说明',
      Object? tags = const ['a', 'b'],
      Object? userId = 'usr_1',
      Object? skills = const ['s1'],
      Object? status = 'active',
      Object? providerType = 'pigo',
      Object? providerConfig = const {'base_url': 'http://x'},
      Object? env = const {'K': 'V'},
      Object? defaultModelId = 'm1',
      Object? modelTier = 'large',
    }) => {
      'id': id,
      'name': name,
      'group_name': groupName,
      'description': '描述',
      'content_md': contentMd,
      'tags': tags,
      'user_id': userId,
      'skills': skills,
      'status': status,
      'provider_type': providerType,
      'provider_config': providerConfig,
      'env': env,
      'default_model_id': defaultModelId,
      'model_tier': modelTier,
      'created_at': '2024-03-05T08:00:00Z',
      'updated_at': '2024-03-05T08:09:10Z',
    };

    test('字段名照抄服务端（snake_case）', () {
      final a = Agent.fromJson(agentJson());
      expect(a.id, 'agt_1');
      expect(a.name, '小助手');
      expect(a.groupName, '默认分组');
      expect(a.contentMd, '# 说明');
      expect(a.tags, ['a', 'b']);
      expect(a.skills, ['s1']);
      expect(a.providerType, 'pigo');
      expect(a.defaultModelId, 'm1');
      expect(a.modelTier, 'large');
      expect(a.createdAt, DateTime.parse('2024-03-05T08:00:00Z').toLocal());
    });

    test('label：名称缺失时回落 id（不显示空白）', () {
      expect(Agent.fromJson(agentJson()).label, '小助手');
      expect(Agent.fromJson(agentJson(name: '')).label, 'agt_1');
      expect(Agent.fromJson(agentJson(name: null)).label, 'agt_1');
    });

    test('isActive：空 status 也算 active；archived 不算', () {
      // 服务端 `filterActive` 只放行 active，但存量行可能 status 为空——
      // 那应视为可用，而不是「未知状态所以不可用」。
      expect(Agent.fromJson(agentJson(status: 'active')).isActive, isTrue);
      expect(Agent.fromJson(agentJson(status: '')).isActive, isTrue);
      expect(Agent.fromJson(agentJson(status: 'archived')).isActive, isFalse);
    });

    test('tags / skills：非列表或含空串时过滤', () {
      final a = Agent.fromJson(
        agentJson(tags: ['a', '', 'b'], skills: 'not-a-list'),
      );
      expect(a.tags, ['a', 'b'], reason: '空串被过滤');
      expect(a.skills, isEmpty, reason: '非列表 → 空列表（不抛）');
    });

    test('provider_config / env 是不透明 Map（含嵌套时保留）', () {
      final a = Agent.fromJson(
        agentJson(
          providerConfig: {'base_url': 'http://x', 'api_key_ref': 'secret_1'},
          env: {
            'NESTED': {'k': 'v'},
          },
        ),
      );
      expect(a.providerConfig?['api_key_ref'], 'secret_1');
      expect(a.env?['NESTED'], isA<Map<dynamic, dynamic>>());
    });

    test('provider_config 非对象时归一成 null（不抛）', () {
      final a = Agent.fromJson(agentJson(providerConfig: 'not-a-map'));
      expect(a.providerConfig, isNull);
    });

    test('缺字段回落安全默认值', () {
      final a = Agent.fromJson(const {});
      expect(a.id, '');
      expect(a.name, '');
      expect(a.tags, isEmpty);
      expect(a.status, '');
      expect(a.providerConfig, isNull);
      expect(a.createdAt, isNull);
      // 空 name 时 label 回落到 id（这里 id 也是空串）。
      expect(a.label, '');
    });

    test('raw 保留原始响应', () {
      final a = Agent.fromJson(agentJson()..['future_field'] = 'x');
      expect(a.raw['future_field'], 'x');
    });
  });

  group('GroupSession（GET /chat/groups/:gid/sessions）', () {
    Map<String, dynamic> sessionJson({
      Object? sessionId = 'ses_1',
      Object? agentSessionId = 'as_1',
      Object? agentName = '小助手',
      Object? agentProvider = 'pigo',
      Object? status = 'active',
    }) => {
      'id': 'bind_1',
      'group_id': 'grp_1',
      'agent_id': 'agt_1',
      'session_id': sessionId,
      'agent_session_id': agentSessionId,
      'agent_name': agentName,
      'agent_provider': agentProvider,
      'role': 'primary',
      'status': status,
      'joined_at': '2024-03-05T08:00:00Z',
      'created_at': '2024-03-05T08:00:00Z',
      'updated_at': '2024-03-05T08:00:05Z',
    };

    test('带 agent_name / agent_provider（下拉要显示名，不能只有 id）', () {
      final s = GroupSession.fromJson(sessionJson());
      expect(s.id, 'bind_1');
      expect(s.groupId, 'grp_1');
      expect(s.agentId, 'agt_1');
      expect(s.agentName, '小助手');
      expect(s.agentProvider, 'pigo');
      expect(s.role, 'primary');
      expect(s.joinedAt, DateTime.parse('2024-03-05T08:00:00Z').toLocal());
    });

    test('session_id 为 null 是**预期**（服务端 lazy 激活）', () {
      // sessions.go：`session_id` 留 NULL，由下一轮 turn 让 executor 自产。
      // 故 UI 不能把「session_id 为空」当成失败。
      final s = GroupSession.fromJson(
        sessionJson(sessionId: null, agentSessionId: null),
      );
      expect(s.sessionId, isNull);
      expect(s.agentSessionId, isNull);
    });

    test('label：agent 名缺失时回落 agent id', () {
      expect(GroupSession.fromJson(sessionJson()).label, '小助手');
      expect(GroupSession.fromJson(sessionJson(agentName: '')).label, 'agt_1');
    });

    test('缺字段回落默认值（不抛）', () {
      final s = GroupSession.fromJson(const {});
      expect(s.id, '');
      expect(s.sessionId, isNull);
      expect(s.agentName, '');
      expect(s.joinedAt, isNull);
    });
  });

  group('GroupAgentSwitchResult（POST .../sessions/switch）', () {
    /// ⚠️ 键名是 `new_agent_id`（**不是** `agent_id`）。
    Map<String, dynamic> switchJson({
      Object? sessionId = 'ses_2',
      Object? switched = true,
      Object? forceNewSession = true,
    }) => {
      'group_id': 'grp_1',
      'new_agent_id': 'agt_2',
      'session_id': sessionId,
      'status': 'active',
      'force_new_session': forceNewSession,
      'switched': switched,
    };

    test('键名是 new_agent_id（写成 agent_id 会得到空串）', () {
      final r = GroupAgentSwitchResult.fromJson(switchJson());
      expect(r.groupId, 'grp_1');
      expect(r.newAgentId, 'agt_2');
      expect(r.sessionId, 'ses_2');
      expect(r.status, 'active');
      expect(r.forceNewSession, isTrue);
      expect(r.switched, isTrue);
    });

    test('session_id 为 null 是预期（lazy 激活）', () {
      final r = GroupAgentSwitchResult.fromJson(switchJson(sessionId: null));
      expect(r.sessionId, isNull);
    });

    test('switched 只认严格 true（HTTP 200 不算成功）', () {
      // 用服务端显式回报判断成功——200 也可能是被中间层改写的响应。
      expect(
        GroupAgentSwitchResult.fromJson(switchJson(switched: true)).switched,
        isTrue,
      );
      expect(
        GroupAgentSwitchResult.fromJson(switchJson(switched: false)).switched,
        isFalse,
      );
      expect(
        GroupAgentSwitchResult.fromJson(switchJson()..remove('switched'))
            .switched,
        isFalse,
      );
      // 字符串 'true' 不算（服务端是 bool）。
      expect(
        GroupAgentSwitchResult.fromJson(switchJson(switched: 'true')).switched,
        isFalse,
      );
    });

    test('缺字段回落默认值', () {
      final r = GroupAgentSwitchResult.fromJson(const {});
      expect(r.groupId, '');
      expect(r.newAgentId, '');
      expect(r.sessionId, isNull);
      expect(r.switched, isFalse);
      expect(r.forceNewSession, isFalse);
    });
  });
}
