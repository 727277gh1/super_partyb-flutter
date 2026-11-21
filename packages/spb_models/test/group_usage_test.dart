import 'package:spb_models/spb_models.dart';
import 'package:test/test.dart';

/// `usage-summary` 响应与 `token_usage` 增量的契约。
///
/// 真源：Go `server/chat_usage.go`（`usageTotals` / `usageAgentRow`）与
/// `chatexec/usage.go`（`TokenUsage.Payload()`）。
void main() {
  group('GroupUsageSummary.fromJson', () {
    test('完整响应：totals 与 by_agent 都解析', () {
      final s = GroupUsageSummary.fromJson(const {
        'totals': {
          'input_tokens': 89100,
          'output_tokens': 42200,
          'cached_tokens': 40000,
          'reasoning_tokens': 1200,
          'total_tokens': 131300,
          'calls': 12,
          'first_at': '2026-11-01T02:03:04Z',
          'last_at': '2026-11-02T02:03:04Z',
        },
        'by_agent': [
          {
            'agent_id': 'agt_1',
            'agent_name': '小明',
            'input_tokens': 60000,
            'output_tokens': 30000,
            'cached_tokens': 20000,
            'calls': 8,
            'last_at': '2026-11-02T02:03:04Z',
          },
          {
            'agent_id': '',
            'agent_name': '未分配',
            'input_tokens': 29100,
            'output_tokens': 12200,
            'cached_tokens': 20000,
            'calls': 4,
          },
        ],
      });

      expect(s.hasData, isTrue);
      expect(s.totals.inputTokens, 89100);
      expect(s.totals.outputTokens, 42200);
      expect(s.totals.cachedTokens, 40000);
      expect(s.totals.reasoningTokens, 1200);
      expect(s.totals.calls, 12);
      expect(s.byAgent.length, 2);
      expect(s.byAgent.first.displayName, '小明');
      // NULL agent_id 由服务端标成「未分配」，客户端照抄。
      expect(s.byAgent.last.agentId, '');
      expect(s.byAgent.last.displayName, '未分配');
      expect(s.byAgent.last.lastAt, '');
    });

    test('burnedTokens = input + output，cached 不加总', () {
      // cached 是 input 的**子集**（cache_read 语义），加进去就是重复计数。
      // 与 webapp `group-chat.ts` 的 tokensBurned 口径逐字一致。
      const t = GroupUsageTotals(
        inputTokens: 100,
        outputTokens: 50,
        cachedTokens: 80,
        calls: 1,
      );
      expect(t.burnedTokens, 150);
    });

    test('展示口径用 burnedTokens，不用服务端 total_tokens', () {
      // 两者可能不等（total 缺失时 Go 用累计兜底），展示只有一个口径。
      const t = GroupUsageTotals(
        inputTokens: 10,
        outputTokens: 5,
        totalTokens: 999,
        calls: 1,
      );
      expect(t.burnedTokens, 15);
      expect(t.totalTokens, 999);
    });

    test('totals 缺失 / 类型不对 → empty（不抛）', () {
      expect(GroupUsageSummary.fromJson(const {}).hasData, isFalse);
      expect(
        GroupUsageSummary.fromJson(const {'totals': 'x'}).hasData,
        isFalse,
      );
      expect(
        GroupUsageSummary.fromJson(const {
          'totals': {'calls': 1},
        }).hasData,
        isTrue,
      );
    });

    test('by_agent 缺失或不是数组 → 空列表', () {
      expect(
        GroupUsageSummary.fromJson(const {'by_agent': 'x'}).byAgent,
        isEmpty,
      );
      expect(
        GroupUsageSummary.fromJson(const {
          'by_agent': [
            'not-a-map',
            {'agent_id': 'a'},
          ],
        }).byAgent.length,
        1,
      );
    });

    test('calls == 0 → hasData false（不渲染全 0 的账单）', () {
      final s = GroupUsageSummary.fromJson(const {
        'totals': {
          'input_tokens': 0,
          'calls': 0,
          'first_at': '',
          'last_at': '',
        },
      });
      expect(s.hasData, isFalse);
      expect(s.totals.firstAtTime, isNull);
    });

    test('first_at / last_at 是 omitempty：缺字段与空串同等对待', () {
      // Go 侧 `json:"first_at,omitempty"`，无数据时键**不存在**。
      final s = GroupUsageSummary.fromJson(const {
        'totals': {'calls': 3},
      });
      expect(s.totals.firstAt, '');
      expect(s.totals.lastAtTime, isNull);
      expect(s.totals.firstAtTime, isNull);
    });

    test('数字字符串可用（服务端 CAST 出来的整数在 JSON 里是数字，但防御性接受串）', () {
      final s = GroupUsageSummary.fromJson(const {
        'totals': {'input_tokens': '120', 'output_tokens': 30.6, 'calls': '2'},
      });
      expect(s.totals.inputTokens, 120);
      expect(s.totals.outputTokens, 31);
      expect(s.totals.calls, 2);
    });

    test('displayName 回退链：name → id → 未分配', () {
      expect(
        const GroupUsageAgentItem(agentId: 'a', agentName: 'N').displayName,
        'N',
      );
      expect(const GroupUsageAgentItem(agentId: 'a').displayName, 'a');
      expect(
        const GroupUsageAgentItem(agentId: 'a', agentName: '').displayName,
        'a',
      );
      expect(const GroupUsageAgentItem().displayName, '未分配');
    });
  });

  group('token_usage 本地增量', () {
    test('calls 恒 +1（不用 payload 的 calls）', () {
      // 服务端合计的 calls 是 `COUNT(*)`（一条事件一个 turn）。payload 里的
      // `calls` 是**本轮内的 LLM 请求帧数**，拿它做增量会让「请求次数」与
      // 服务端聚合永久漂移（刷新前偏大、刷新后突然变小）。
      final base = GroupUsageSummary.fromJson(const {
        'totals': {'input_tokens': 10, 'output_tokens': 5, 'calls': 1},
      });
      final next = base.incrementedByEvent(const {
        'input_tokens': 100,
        'output_tokens': 20,
        'calls': 7, // ← 本轮调了 7 次 LLM，但对「有账单的 turn 数」只贡献 1
      });
      expect(next.totals.calls, 2);
      expect(next.totals.inputTokens, 110);
      expect(next.totals.outputTokens, 25);
    });

    test('零值字段缺键时按 0（Go omitempty）', () {
      final base = GroupUsageSummary.fromJson(const {
        'totals': {'input_tokens': 10, 'output_tokens': 5, 'calls': 1},
      });
      final next = base.incrementedByEvent(const {
        'input_tokens': 1,
        'output_tokens': 1,
      });
      expect(next.totals.cachedTokens, 0);
      expect(next.totals.reasoningTokens, 0);
      expect(next.totals.totalTokens, 0);
    });

    test('total_tokens 缺失加 0（与后端 COALESCE(SUM(...),0) 同口径）', () {
      final base = GroupUsageSummary.fromJson(const {
        'totals': {'input_tokens': 1, 'total_tokens': 9, 'calls': 1},
      });
      final next = base.incrementedByEvent(const {
        'input_tokens': 1,
        'output_tokens': 1,
      });
      expect(next.totals.totalTokens, 9);
    });

    test('基线没有时间时由增量补上 first_at / last_at', () {
      final base = GroupUsageSummary.fromJson(const {
        'totals': {'input_tokens': 1, 'output_tokens': 1, 'calls': 1},
      });
      expect(base.totals.firstAtTime, isNull);
      final next = base.incrementedByEvent(const {
        'input_tokens': 1,
      }, occurredAt: '2026-11-03T00:00:00Z');
      // 真实事件时间，不是伪造的账单——首条记录时间就该是它。
      expect(next.totals.firstAt, '2026-11-03T00:00:00Z');
      expect(next.totals.lastAt, '2026-11-03T00:00:00Z');
    });

    test('基线已有 first_at 时不被增量改写；last_at 前进', () {
      final base = GroupUsageSummary.fromJson(const {
        'totals': {
          'calls': 1,
          'first_at': '2026-11-01T00:00:00Z',
          'last_at': '2026-11-01T01:00:00Z',
        },
      });
      final next = base.incrementedByEvent(const {
        'input_tokens': 1,
      }, occurredAt: '2026-11-05T00:00:00Z');
      expect(next.totals.firstAt, '2026-11-01T00:00:00Z');
      expect(next.totals.lastAt, '2026-11-05T00:00:00Z');
    });

    test('增量不带时间时保留旧的 last_at', () {
      final base = GroupUsageSummary.fromJson(const {
        'totals': {'calls': 1, 'last_at': '2026-11-01T01:00:00Z'},
      });
      final next = base.incrementedByEvent(const {'input_tokens': 1});
      expect(next.totals.lastAt, '2026-11-01T01:00:00Z');
    });

    test('by_agent 不做本地合并（保持基线那份）', () {
      // 要正确合并就得复刻服务端的 NULL / 改名 / 分组逻辑，而它只在低频的
      // 分布视图使用 → 交给下次拉取刷新（webapp 同一取舍）。
      final base = GroupUsageSummary.fromJson(const {
        'totals': {'calls': 1},
        'by_agent': [
          {'agent_id': 'a', 'calls': 1},
        ],
      });
      final next = base.incrementedByEvent(const {'input_tokens': 5});
      expect(next.byAgent.length, 1);
      expect(next.byAgent.single.calls, 1);
    });

    test('增量返回新实例，不修改基线', () {
      final base = GroupUsageSummary.fromJson(const {
        'totals': {'input_tokens': 10, 'calls': 1},
      });
      base.incrementedByEvent(const {'input_tokens': 10});
      expect(base.totals.inputTokens, 10);
      expect(base.totals.calls, 1);
    });

    test('空 payload 也推进 calls（一条事件 = 一个有账单的 turn）', () {
      final base = GroupUsageSummary.fromJson(const {
        'totals': {'calls': 1},
      });
      expect(base.incrementedByEvent(const {}).totals.calls, 2);
    });
  });

  group('EventTypes', () {
    test('token_usage 在 all 里（服务端契约已知）', () {
      expect(EventTypes.all, contains(EventTypes.tokenUsage));
      expect(EventTypes.tokenUsage, 'token_usage');
    });

    test('token_usage **不在** timelineVisible 里（观测数据不挤占对话事件）', () {
      // 进了白名单就会在时间线上多出「用量」条目，把对话冲散；
      // 它只服务于顶部读数与游标推进。
      expect(
        EventTypes.timelineVisible,
        isNot(contains(EventTypes.tokenUsage)),
      );
    });
  });
}
