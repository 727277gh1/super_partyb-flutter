import 'package:dio/dio.dart';
import 'package:http_mock_adapter/http_mock_adapter.dart';
import 'package:spb_api/spb_api.dart';
import 'package:test/test.dart';

/// `ChatApi` 契约测试的共享夹具（issue #48 从 `chat_api_test.dart` 抽出）。
///
/// ## 为什么是「顶层变量 + setUpHarness()」而不是一个类
///
/// 原文件的测试体直接写 `api.pendingMessages(...)` / `adapter.onGet(...)`。
/// 抽成一个类（`harness.api.xxx`）要改**每一处**调用点——那就不是「纯移动」
/// 了，diff 会混入 200+ 处机械改写，审阅者无法分辨「搬家」与「真改动」。
///
/// 顶层 `late` 变量 + 在 `main()` 开头调一次 `setUpHarness()`，则调用点
/// **逐字不变**（`api.xxx` 仍然有效），diff 里只有「删掉声明块 + 加一行
/// import/setUpHarness」。
///
/// ⚠️ 每个测试文件各自 `import` 这份夹具，各自调 `setUpHarness()`。Dart 的
/// 测试隔离以**文件**为界（`dart test` 每个文件独立 isolate），故跨文件
/// 共享顶层变量是安全的；同文件内 `setUp` 保证每条用例从干净状态开始。
///
/// ⚠️ 不要把它放进 `lib/`：那会让测试夹具进生产产物（`spb_features` 的
/// `test/support/` 是既有先例，见 `tools/check_test_support_sync.sh` 头注）。
late Dio dio;
late DioAdapter adapter;
late ChatApi api;

/// 在 `main()` 开头调用一次，装配共享的 `setUp`。
void setUpHarness() {
  setUp(() {
    dio = createDio(baseUrl: 'https://api.test/pba');
    adapter = DioAdapter(dio: dio);
    api = ChatApi(dio);
  });
}

/// `inboxToDict` 的真实输出形状（`internal/server/chat_inbox.go`）。
///
/// `ChatApi.pendingMessages` 的契约测试用（原 `chat_api_test.dart` 的
/// `inboxToDictShape`，issue #48 随夹具一起抽出——它被 4 个 group 共用）。
Map<String, dynamic> inboxToDictShape({
  String id = 'inbox_01HZ',
  String status = 'pending',
  String? groupId = 'grp_1',
  String? turnId,
  String? processedAt,
}) => {
  'id': id,
  'user_id': 'usr_01HZW',
  'group_id': groupId,
  'request_id': 'req_1',
  'agent_id': 'agt_1',
  'agent_type': 'pigo',
  'input': '帮我看一下这个报错',
  'status': status,
  'turn_id': turnId,
  'payload': {'source': 'bridge', 'channel': 'wechat_ilink'},
  'result': {'status': 'committed', 'strategy': 'latest'},
  'created_at': '2024-03-05T08:09:10Z',
  'updated_at': '2024-03-05T08:09:12Z',
  'processed_at': processedAt,
};
