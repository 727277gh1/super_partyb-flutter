/// spec JSON（JsonUiSchema）解析层——服务端 `spec_schema` 的纯 Dart 模型与解析。
///
/// ## 这是什么（只覆盖服务端确定编译的产出，不是通用渲染协议）
///
/// 服务端有三类 `spec_schema` 生产者，全部由**确定性 Go 代码**编译（非 LLM 生成 UI）：
///
/// | 生产者 | 事件 / 场景 | type 大小写 | 动作位置 |
/// |---|---|---|---|
/// | `chatgate/goal_gate_spec.go` buildTaskSpec | goal_gate_decision 进度卡 | **小写**（card/progress/metric） | 无 |
/// | `chatgate/followup_suggest.go` BuildFollowUpSpecJSON | follow_up_suggested 建议卡 | **首字母大写**（Card/Text/Button） | `on.click[]`（字段名 `action`） |
/// | `chatpipeline/classify_feedback.go` BuildClassifyFeedbackSpecJSON | 归属反馈卡 | 首字母大写 | `actions[]`（字段名 **`type`**） |
///
/// 三处连「动作字段叫 action 还是 type」都不一致——解析器必须同时覆盖，且对
/// type 大小写不敏感。这些差异没有服务端契约保证，故客户端**降级优先**：
/// 未知 type、悬空 children、环引用、缺字段一律不抛异常。
///
/// ## 为什么放在 spb_domain（而不是 spb_models）
///
/// 解析输出要被归约层与渲染组件共同消费，且「白名单之外视为 unknown」这个
/// 判定是**领域规则**（决定 UI 降级策略）。spb_models 只做字段镜像，不含规则。
///
/// ## 安全约束
///
/// - **绝不抛异常**：spec 是服务端 payload 的一个字段，形状漂移不该炸掉时间线；
/// - **环检测 + 深度上限**：children 是 id 引用，恶意/损坏数据可以自环；
///   回放历史事件时栈溢出比渲染错误更糟。
library;

/// 服务端实际会产出的元素类型（白名单，对齐 webapp JsonUiSchemaRenderer 的
/// renderXxx 分发；大小写不敏感）。
enum SpecUiType {
  card,
  progress,
  metric,
  text,
  heading,
  button,
  list,
  listItem,
  separator,
  badge,
  alert,
  code,

  /// 白名单之外的类型。**不抛错**：服务端新增 type 时老客户端降级为占位，
  /// 时间线其余部分照常渲染。
  ///
  /// 原始字符串保留在 [SpecUiElement.rawType]——枚举本身丢掉了大小写与
  /// 具体类型名，占位符要显示「缺哪个类型」只能靠它（issue #27）。
  unknown;

  /// 从服务端原始 type 字符串解析（大小写不敏感）。
  static SpecUiType from(String? raw) {
    switch (raw?.toLowerCase().trim()) {
      case 'card':
        return card;
      case 'progress':
        return progress;
      case 'metric':
        return metric;
      case 'text':
        return text;
      case 'heading':
        return heading;
      case 'button':
        return button;
      case 'list':
        return list;
      case 'listitem':
        return listItem;
      case 'separator':
      case 'divider':
        return separator;
      case 'badge':
        return badge;
      case 'alert':
        return alert;
      case 'code':
        return code;
      default:
        return unknown;
    }
  }
}

/// 元素上声明的动作。
///
/// 服务端两类动作的位置与字段名都不一致（见文件头表格）：
///
/// - follow_up：`on.click[]`，`{action: "copy_text", params: {text, label, agent_id?}}`
/// - classify_feedback：`actions[]`，`{type: "send_next_input", label, nextInput}`
enum SpecUiActionType { copyText, sendNextInput, unknown }

/// 一个可交互动作的解析结果。
final class SpecUiAction {
  const SpecUiAction({
    required this.type,
    this.label = '',
    this.text = '',
    this.nextInput = '',
    this.agentId = '',
  });

  final SpecUiActionType type;

  /// 动作的展示文字（两处产出都有：on.click 的 params.label / actions 的 label）。
  final String label;

  /// `copy_text` 的负载文本（如建议的问题全文）。
  final String text;

  /// `send_next_input` 的待发送文本（如「反馈#正确」）。
  final String nextInput;

  /// 建议适用的 agent（follow_up 独有，可选）。空串表示未指定。
  final String agentId;

  /// 诊断用（不含负载文本，避免日志刷屏）。
  @override
  String toString() =>
      'SpecUiAction(type: $type, label: $label, agentId: $agentId)';
}

/// spec 树中的一个元素。
final class SpecUiElement {
  const SpecUiElement({
    required this.id,
    required this.type,
    this.rawType = '',
    this.props = const {},
    this.childIds = const [],
    this.actions = const [],
  });

  /// 元素标识。**来自 elements 的 map 键**——goal_gate 的产出元素体内没有
  /// id 字段，只有键名能当 id 用（这是核实后的真实形状，不能假设有 id 字段）。
  final String id;

  final SpecUiType type;

  /// 服务端原始 type 字符串（**未归一化**：保留大小写与下划线）。
  ///
  /// ## 为什么必须保留（issue #27）
  ///
  /// [type] 是枚举，白名单外的类型全部塌缩成 [SpecUiType.unknown]，故
  /// `type.name` 对 `Stack` / `Grid` / `Chart` 一律打印 `unknown`——占位符的
  /// **诊断价值为零**：用户与开发者都看不出到底缺哪个类型。
  ///
  /// 另注：原始字符串可能为空（服务端未写 `type` 字段），此时 [type] 也是
  /// [SpecUiType.unknown]。
  final String rawType;

  /// 渲染所需的原始 props（title/content/value/label/hint 等）。
  /// 不做字段级归一：不同 type 读的键不同，归一放渲染层。
  final Map<String, Object?> props;

  /// 子元素 id 列表（**引用**，解析在 [SpecUiDocument.childrenOf]）。
  /// 可能含悬空 id（指向不存在的元素）——遍历时跳过，不在解析期报错。
  final List<String> childIds;

  final List<SpecUiAction> actions;

  /// 读 props 里的字符串字段（缺省空串）。
  String prop(String key) => props[key]?.toString() ?? '';

  /// 读 props 里的数值字段（容忍 int/double/字符串）。
  double? propNum(String key) {
    final v = props[key];
    if (v is num) return v.toDouble();
    if (v is String) return double.tryParse(v);
    return null;
  }

  @override
  String toString() =>
      'SpecUiElement($id, ${rawType.isEmpty ? type.name : rawType}, '
      'children: $childIds, actions: $actions)';
}

/// 解析完成的 spec 文档：root + 元素表 + 安全遍历。
final class SpecUiDocument {
  const SpecUiDocument({required this.rootId, required this.elements});

  /// 根元素 id（`root` 字段）。可能指向不存在的元素（悬空 root）。
  final String rootId;

  /// 元素表（键 = 元素 id）。
  final Map<String, SpecUiElement> elements;

  /// 根元素；悬空 root 时为 null。
  SpecUiElement? get root => elements[rootId];

  /// [element] 的**直接**子元素（按 childIds 顺序），跳过悬空引用与自引用。
  ///
  /// ## 与 [childrenOf] 的分工（issue #27）
  ///
  /// 渲染器**必须**用这个而不是 [childrenOf]：[childrenOf] 返回的是**整棵子树
  /// 的扁平列表**，而渲染器对每个子元素都会再递归一次——两者叠加会让深层元素
  /// **渲染多次**（实测：3 层树里叶子出现 2 次）。这是本方法存在的全部理由。
  ///
  /// 自引用（`children` 含自身 id）直接跳过：递归渲染时它必然被祖先集合拦下，
  /// 但提前过滤能让「A→A」这种数据不必依赖渲染层兜底。
  List<SpecUiElement> directChildrenOf(SpecUiElement element) {
    final out = <SpecUiElement>[];
    for (final id in element.childIds) {
      if (id == element.id) continue; // 自引用：跳过。
      final child = elements[id];
      if (child == null) continue; // 悬空引用：跳过。
      out.add(child);
    }
    return out;
  }

  /// 遍历 [element] 的子树（广度优先、按 childIds 顺序），返回扁平列表。
  ///
  /// ## 四个安全边界
  ///
  /// - **悬空引用**：childIds 里指向不存在的 id → 跳过（不是错误——服务端
  ///   各生产者都不保证 children 与 elements 严格一致）；
  /// - **环引用**：id 已在访问集合中 → 停止沿该分支下钻（数据损坏时防止
  ///   无限循环）；
  /// - **深度上限**（[maxDepth]，默认 32）：超深嵌套按截断处理。服务端真实
  ///   产出最多 3 层（card → text/button），32 已是数量级余量。
  /// - **条数上限**（[limit]，默认 64）：扁平列表本身也要有界。深度上限挡不住
  ///   「宽」的树——一个 children 里塞 10 万个 id 的 payload 在深度上只算 1 层，
  ///   却会让调用方构造出同样多的 widget。
  List<SpecUiElement> childrenOf(
    SpecUiElement element, {
    int maxDepth = 32,
    int limit = 64,
  }) {
    final out = <SpecUiElement>[];
    final visited = <String>{element.id};
    void walk(String id, int depth) {
      if (depth > maxDepth || out.length >= limit) return;
      final child = elements[id];
      if (child == null) return; // 悬空引用：跳过。
      if (!visited.add(child.id)) return; // 环：停止下钻。
      out.add(child);
      for (final grandChild in child.childIds) {
        walk(grandChild, depth + 1);
      }
    }

    for (final id in element.childIds) {
      walk(id, 1);
    }
    return out;
  }
}

/// 解析服务端 `spec_schema`（`{root, elements}` 形状）。
///
/// 任何异常输入（null / 非 Map / 缺 elements / 元素形状不对）都返回 null
/// 而非抛异常——调用方降级为「没有 spec」照常渲染其余 payload 字段。
///
/// 元素体内的 `id` 字段若存在则**以 map 键为准**：三个生产者中两个不写 id
/// 字段、写的那两个键值恒等，取键名是三者共同的真源。
SpecUiDocument? parseSpecUi(Object? raw) {
  if (raw is! Map) return null;
  final rootId = raw['root']?.toString() ?? '';
  final rawElements = raw['elements'];
  if (rootId.isEmpty || rawElements is! Map) return null;

  final elements = <String, SpecUiElement>{};
  rawElements.forEach((key, value) {
    if (value is! Map) return; // 元素形状不对：跳过该元素，不影响其余。
    final id = key.toString();
    final rawType = value['type']?.toString() ?? '';
    elements[id] = SpecUiElement(
      id: id,
      type: SpecUiType.from(rawType),
      rawType: rawType,
      props: value['props'] is Map
          ? Map<String, Object?>.from(value['props'] as Map)
          : const {},
      childIds: _stringList(value['children']),
      actions: _actions(value),
    );
  });

  return SpecUiDocument(rootId: rootId, elements: elements);
}

/// 收集元素的动作：`actions[]` 与 `on.click[]` 两处都要扫（见文件头表格——
/// 两类生产者各写一处，字段名也不同：actions 用 `type`，on.click 用 `action`）。
List<SpecUiAction> _actions(Map<Object?, Object?> element) {
  final out = <SpecUiAction>[];

  void addFrom(Object? raw, String typeKey) {
    if (raw is! List) return;
    for (final item in raw) {
      if (item is! Map) continue;
      final actionType = item[typeKey]?.toString();
      final params = item['params'] is Map
          ? Map<String, Object?>.from(item['params'] as Map)
          : const <String, Object?>{};
      out.add(
        SpecUiAction(
          type: switch (actionType) {
            'copy_text' => SpecUiActionType.copyText,
            'send_next_input' => SpecUiActionType.sendNextInput,
            _ => SpecUiActionType.unknown,
          },
          label: (item['label'] ?? params['label'] ?? '').toString(),
          text: (params['text'] ?? params['nextInput'] ?? '').toString(),
          nextInput: (item['nextInput'] ?? params['text'] ?? '').toString(),
          agentId: (params['agent_id'] ?? '').toString(),
        ),
      );
    }
  }

  addFrom(element['actions'], 'type');
  final onClick = element['on'];
  if (onClick is Map) {
    addFrom(onClick['click'], 'action');
  }
  return out;
}

/// 元素的 children 字符串列表（容忍混合类型，非字符串项丢弃）。
List<String> _stringList(Object? raw) {
  if (raw is! List) return const [];
  return [
    for (final item in raw)
      if (item is String && item.isNotEmpty) item,
  ];
}
