import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:spb_models/spb_models.dart';

import '../support/conversation_page_harness.dart';

/// 系统字体缩放（a11y）守卫（§6.80）。
///
/// ## 这个文件防的两件事
///
/// | 防什么 | 为什么重要 |
/// |---|---|
/// | 大字号下布局溢出（`RenderFlex overflowed`） | 溢出是**硬失败**（黄黑斜纹），用户会看到半个字被切掉。固定高度容器（`SizedBox(height:)`、`Chip`、角标）是主要来源 |
/// | 有人「顺手」把 `MediaQuery.textScaler` clamp 掉 | 那会让 2 倍字号的用户永远只能拿到 1.3 倍——静默吞掉无障碍设置，且不会有人发现（测试里没人设过大字号） |
///
/// ## 为什么用 2.0 而不是 Android 的「最大字体」
///
/// Android 的字体倍率上限随版本变化（1.3 / 1.6 / 2.0），iOS 的
/// Accessibility 档可以更大。取 **2.0** —— 常见上限里最大的一个，且
/// 一旦在 2.0 下不溢出，更小的档位自然安全（正文是线性放大，布局余量单调）。
///
/// ## 怎么设倍率
///
/// `tester.binding.platformDispatcher.textScaleFactorTestValue` ——
/// `MaterialApp` 从这里派生 `MediaQuery`。**不要**直接给
/// `MediaQuery(data: ...)`，那绕过了 `MaterialApp` 的真实装配路径，测不到
/// 应用层的缩放策略。
void main() {
  setUpHarness();
  tearDownHarness();

  /// 以 [factor] 倍系统字号跑本用例，结束时还原（否则会污染同文件后续用例）。
  void useTextScale(WidgetTester tester, double factor) {
    tester.binding.platformDispatcher.textScaleFactorTestValue = factor;
    addTearDown(
      tester.binding.platformDispatcher.clearTextScaleFactorTestValue,
    );
  }

  /// 灌入一段「真实长度」的对话：长标题 + 长输入 + 多段回复 + 工具调用。
  /// 都取偏长的文案，因为溢出恰恰发生在「文案比设计稿长」的时候。
  Future<void> pumpRealisticConversation(WidgetTester tester) async {
    mockTimeline();
    await startController(tester);
    await pumpPage(tester, title: '这是一段很长很长的对话标题，用来挤压左侧返回按钮和右侧操作区');

    await pushEvent(
      tester,
      EventTypes.userMessage,
      sseEvent(
        'user_message',
        id: 'e1',
        payload: {'input': '帮我看看这个任务的进度，顺便说明一下为什么还没完成，以及下一步打算怎么处理'},
      ),
    );
    await pushEvent(
      tester,
      EventTypes.message,
      sseEvent(
        'message',
        id: 'e2',
        payload: {
          'text':
              '好的，我先看一下当前任务的执行情况。目前有三个子任务在进行中，'
              '其中一个被阻塞了，原因是依赖的上游接口还没有就绪。\n\n'
              '下一步我会联系上游确认时间点，同时把可以并行的部分先推进。',
        },
        seq: 2,
      ),
    );
    await pushEvent(
      tester,
      EventTypes.toolCall,
      sseEvent(
        'tool_call',
        id: 'e3',
        payload: {
          'tool': 'read_file',
          'args': {
            'path':
                '/root/very/long/path/that/keeps/going/and/going/forever.txt',
          },
        },
        seq: 3,
      ),
    );
    // 对话页有常驻动画（流式指示器），`pumpAndSettle` 会一直等到超时。
    await tester.pump(const Duration(milliseconds: 200));
    await tester.pump(const Duration(milliseconds: 200));
  }

  group('对话页在系统字号放大时', () {
    for (final factor in [1.3, 2.0]) {
      testWidgets('$factor 倍：不抛溢出异常，主要内容仍在', (tester) async {
        useTextScale(tester, factor);
        // 放大后一屏装的字少，用高一点的画布，避免「内容被滚出屏幕」被误判
        // 成溢出（本用例测的是**布局**，不是滚动）。
        tester.view.physicalSize = const Size(1000, 1600);
        tester.view.devicePixelRatio = 1.0;
        addTearDown(tester.view.reset);

        await pumpRealisticConversation(tester);

        // `RenderFlex overflowed` / `A RenderFlex overflowed by …` 都会以
        // `FlutterError` 的形式抛到这里。
        expect(
          tester.takeException(),
          isNull,
          reason: '$factor 倍系统字号下不允许有布局溢出（§6.80）',
        );

        expect(
          find.textContaining('三个子任务在进行中', findRichText: true),
          findsOneWidget,
          reason: '放大后助手回复仍渲染（溢出时它会整段消失）',
        );
      });
    }
  });

  group('缩放没有被偷偷 clamp 掉', () {
    testWidgets('2.0 倍下正文的实际渲染高度确实翻倍', (tester) async {
      // 这条用例的意义：**防止**有人为了「修溢出」而在
      // `MaterialApp.builder` 里把 textScaler 夹到 1.3 —— 那样溢出没了、
      // 无障碍也没了，且现有测试**一条都不会红**。这里量的是真实布局尺寸，
      // 不是「有没有调用 setter」。
      Future<double> renderedHeight(double factor) async {
        useTextScale(tester, factor);
        mockTimeline();
        await startController(tester);
        await pumpPage(tester);
        await pushEvent(
          tester,
          EventTypes.userMessage,
          sseEvent('user_message', id: 'scaled', payload: {'input': '一句话'}),
        );
        await tester.pump(const Duration(milliseconds: 200));
        return tester.getSize(find.text('一句话')).height;
      }

      // 两个倍率在**同一个** tester 里跑：换 widget 前先把上一轮的框架清掉。
      final h1 = await renderedHeight(1.0);
      await tester.pumpWidget(const SizedBox.shrink());
      final h2 = await renderedHeight(2.0);

      expect(
        h2 / h1,
        moreOrLessEquals(2.0, epsilon: 0.15),
        reason: '2.0 倍系统字号必须真的放大到 2 倍（被 clamp 过就不是 2 了）',
      );
    });
  });
}
