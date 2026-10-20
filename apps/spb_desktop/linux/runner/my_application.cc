#include "my_application.h"

#include <flutter_linux/flutter_linux.h>
#include <gio/gio.h>
#ifdef GDK_WINDOWING_X11
#include <gdk/gdkx.h>
#endif

#include "flutter/generated_plugin_registrant.h"

// 剪贴板文件读取通道名。
//
// ⚠️ 必须与 Dart 侧逐字一致：packages/spb_platform/lib/src/overlay_files.dart
// 的 `MethodChannel('com.atjog.spb/clipboard_files')`。写错不会报错，只会
// 表现为 Dart 侧收到 MissingPluginException 并静默降级——即「粘贴没反应」，
// 与「平台根本没实现」完全无法区分。
static const char kClipboardFilesChannelName[] =
    "com.atjog.spb/clipboard_files";

// 单文件读取上限（OOM 兜底）。
//
// Dart 侧真正的策略上限是 kOverlayMaxAttachmentBytes = 50 MiB，但那个判断
// 发生在字节**已经读进内存之后**。剪贴板里可能是一份 GB 级的镜像，直接
// g_file_get_contents 会把进程推向 OOM——Linux 上通常表现为被 OOM killer
// 杀掉（SIGKILL，无堆栈），而不是干净地返回一个错误。
//
// 这里只是一个远高于正常附件大小的兜底值，不是产品策略；超过就跳过该项并
// 告警，让用户改用「添加文件」按钮走流式上传。
static const goffset kClipboardMaxFileBytes = 512LL * 1024 * 1024;

struct _MyApplication {
  GtkApplication parent_instance;
  char** dart_entrypoint_arguments;

  // 剪贴板文件读取通道。由 activate 注册、dispose 释放。
  FlMethodChannel* clipboard_channel;
};

G_DEFINE_TYPE(MyApplication, my_application, GTK_TYPE_APPLICATION)

// 把剪贴板里的一个 URI 转成本机绝对路径；不是本地文件则返回 nullptr。
//
// ## 为什么用 g_filename_from_uri，而不是「剥掉 file:// 前缀 +
//    g_uri_unescape_string」
//
// 三个理由，都是实测出来的：
//
// 1. **远端主机必须拒绝。** `file://evil.com/etc/passwd` 若只剥前缀会得到
//    `/etc/passwd`——把一个网络路径当成本地路径读。g_filename_from_uri 通过
//    hostname 出参告诉我们 host 是 `evil.com`，据此可以拒掉。
//
// 2. **反转义只能做一次。** 文件名里字面含 `%` 时，URI 是双写的
//    （`100%.txt` → `file:///path/to/100%25.txt`）。g_filename_from_uri
//    解出的已经是字面 `100%.txt`；再调一次 g_uri_unescape_string 会因
//    `%.t` 不是合法转义而返回 NULL（实测），把合法文件丢掉。
//
// 3. **它会拒绝 %2F 这类「用编码藏一个路径分隔符」的 URI**（实测返回
//    NULL + "contains invalidly escaped characters"）。手写剥前缀则会把它
//    解成一个真的分隔符。
//
// 返回 NULL 的三种情况（远端 host / 非 file scheme / 非法转义）在调用方
// 一律按「跳过该项」处理，不影响其余 URI。
static gchar* clipboard_uri_to_local_path(const gchar* uri) {
  g_autoptr(GError) error = nullptr;
  gchar* host = nullptr;
  gchar* path = g_filename_from_uri(uri, &host, &error);

  if (path == nullptr) {
    // 非 file scheme / 非法转义。debug 级别：用户从网页复制的普通链接
    // 也会走到这里，属于预期情况而非故障。
    g_debug("剪贴板 URI 不是本地文件，跳过：%s",
            error != nullptr ? error->message : uri);
    g_free(host);
    return nullptr;
  }

  // 有 host 的 file:// URI 指向别的机器（`file://localhost/...` 也会给出
  // host=localhost）。这里一律从严拒绝：文件管理器复制文件时放的是
  // `file:///...`（host 为空），localhost 形式在实践中不出现，而放宽它
  // 只会多开一条「网络路径当本地路径」的口子。失败方向是「用户拿不到这个
  // 附件」，而不是「读了一个不该读的文件」。
  if (host != nullptr) {
    g_debug("剪贴板 URI 指向远端主机 %s，跳过", host);
    g_free(host);
    g_free(path);
    return nullptr;
  }

  return path;
}

// 读一个本地文件并组装成 Dart 侧的 {name, bytes} 条目；失败返回 nullptr。
//
// 返回的 FlValue 是 transfer-full（调用方负责 unref / 交给 take 型 API）。
static FlValue* clipboard_read_file_entry(const gchar* path) {
  g_autoptr(GError) error = nullptr;

  g_autoptr(GFile) file = g_file_new_for_path(path);
  g_autoptr(GFileInfo) info = g_file_query_info(
      file, G_FILE_ATTRIBUTE_STANDARD_SIZE, G_FILE_QUERY_INFO_NONE, nullptr,
      &error);
  if (info == nullptr) {
    g_warning("剪贴板文件不可读，跳过 %s：%s", path, error->message);
    return nullptr;
  }

  goffset size = g_file_info_get_size(info);
  if (size > kClipboardMaxFileBytes) {
    g_warning("剪贴板文件超过 %" G_GOFFSET_FORMAT
              " 字节，跳过 %s（请改用「添加文件」按钮）",
              kClipboardMaxFileBytes, path);
    return nullptr;
  }

  g_autofree gchar* contents = nullptr;
  gsize length = 0;
  if (!g_file_get_contents(path, &contents, &length, &error)) {
    // 权限不足 / 读一半被删 / 是目录：跳过该项，不拖垮整批。
    g_warning("读取剪贴板文件失败，跳过 %s：%s", path, error->message);
    return nullptr;
  }

  g_autofree gchar* name = g_path_get_basename(path);

  // 注意所有权与拷贝语义：
  //  - fl_value_new_uint8_list 会**复制** contents（fl_value.cc 里 memcpy），
  //    故随后 g_autofree 释放是安全的，不会留下悬垂指针；
  //  - set_string_take 接管 value 的所有权，故不能再 unref 这些子值。
  FlValue* entry = fl_value_new_map();
  fl_value_set_string_take(entry, "name", fl_value_new_string(name));
  fl_value_set_string_take(
      entry, "bytes",
      fl_value_new_uint8_list((const uint8_t*)contents, (size_t)length));
  return entry;
}

// 读剪贴板里的文件列表，组装成 Dart 侧期望的 List<Map>。
//
// ## 为什么「没有文件」返回空列表而不是错误
//
// Dart 侧把空列表当作「剪贴板里没有文件，降级为文本粘贴」（见
// overlay_files.dart 的 readClipboardFiles）。若这里回 error，用户从网页
// 复制一段文字再 Ctrl+V 就会看到一条失败提示——而那是完全正常的操作。
//
// ## 为什么是 wait_for_uris 而不是 wait_for_text
//
// 文件管理器里 Ctrl+C 一个文件时，剪贴板放的是 `text/uri-list`（一行一个
// URI），不是纯文本。wait_for_text 会拿到拼接后的字符串且丢失 MIME 信息，
// 无法区分「复制了文件」与「复制了看起来像路径的文本」。
//
// ## 已知代价：这是同步阻塞调用
//
// gtk_clipboard_wait_for_* 会跑一个嵌套主循环等待剪贴板所有者应答，期间
// UI 冻结（通常几十毫秒，剪贴板所有者无响应时可到数秒）。异步版本需要
// gtk_clipboard_request_uris + 延后回复 FlMethodCall，复杂度显著更高；
// 这里按「粘贴是用户主动触发的低频操作」接受该代价。
static FlValue* clipboard_read_files() {
  g_autoptr(FlValue) files = fl_value_new_list();

  gchar** uris =
      gtk_clipboard_wait_for_uris(gtk_clipboard_get(GDK_SELECTION_CLIPBOARD));
  if (uris == nullptr) {
    // 剪贴板里是纯文本 / 图片 / 空：没有 URI 列表。
    return g_steal_pointer(&files);
  }

  for (gchar** it = uris; *it != nullptr; it++) {
    g_autofree gchar* path = clipboard_uri_to_local_path(*it);
    if (path == nullptr) {
      continue;
    }
    FlValue* entry = clipboard_read_file_entry(path);
    if (entry == nullptr) {
      continue;  // 单项失败不影响其余 URI
    }
    fl_value_append_take(files, entry);
  }

  g_strfreev(uris);
  return g_steal_pointer(&files);
}

// 通道方法分发。
static void clipboard_method_call_cb(FlMethodChannel* channel,
                                     FlMethodCall* method_call,
                                     gpointer user_data) {
  g_autoptr(GError) error = nullptr;

  if (g_strcmp0(fl_method_call_get_name(method_call), "readFiles") != 0) {
    fl_method_call_respond_not_implemented(method_call, &error);
    if (error != nullptr) {
      g_warning("回复剪贴板通道的未知方法失败：%s", error->message);
    }
    return;
  }

  g_autoptr(FlValue) result = clipboard_read_files();
  if (!fl_method_call_respond_success(method_call, result, &error)) {
    g_warning("回复剪贴板文件读取结果失败：%s", error->message);
  }
}

// Called when first Flutter frame received.
static void first_frame_cb(MyApplication* self, FlView* view) {
  gtk_widget_show(gtk_widget_get_toplevel(GTK_WIDGET(view)));
}

// Implements GApplication::activate.
static void my_application_activate(GApplication* application) {
  MyApplication* self = MY_APPLICATION(application);
  GtkWindow* window =
      GTK_WINDOW(gtk_application_window_new(GTK_APPLICATION(application)));

  // Use a header bar when running in GNOME as this is the common style used
  // by applications and is the setup most users will be using (e.g. Ubuntu
  // desktop).
  // If running on X and not using GNOME then just use a traditional title bar
  // in case the window manager does more exotic layout, e.g. tiling.
  // If running on Wayland assume the header bar will work (may need changing
  // if future cases occur).
  gboolean use_header_bar = TRUE;
#ifdef GDK_WINDOWING_X11
  GdkScreen* screen = gtk_window_get_screen(window);
  if (GDK_IS_X11_SCREEN(screen)) {
    const gchar* wm_name = gdk_x11_screen_get_window_manager_name(screen);
    if (g_strcmp0(wm_name, "GNOME Shell") != 0) {
      use_header_bar = FALSE;
    }
  }
#endif
  if (use_header_bar) {
    GtkHeaderBar* header_bar = GTK_HEADER_BAR(gtk_header_bar_new());
    gtk_widget_show(GTK_WIDGET(header_bar));
    gtk_header_bar_set_title(header_bar, "spb_desktop");
    gtk_header_bar_set_show_close_button(header_bar, TRUE);
    gtk_window_set_titlebar(window, GTK_WIDGET(header_bar));
  } else {
    gtk_window_set_title(window, "spb_desktop");
  }

  gtk_window_set_default_size(window, 1280, 720);

  g_autoptr(FlDartProject) project = fl_dart_project_new();
  fl_dart_project_set_dart_entrypoint_arguments(
      project, self->dart_entrypoint_arguments);

  FlView* view = fl_view_new(project);
  GdkRGBA background_color;
  // Background defaults to black, override it here if necessary, e.g. #00000000
  // for transparent.
  gdk_rgba_parse(&background_color, "#000000");
  fl_view_set_background_color(view, &background_color);
  gtk_widget_show(GTK_WIDGET(view));
  gtk_container_add(GTK_CONTAINER(window), GTK_WIDGET(view));

  // Show the window when Flutter renders.
  // Requires the view to be realized so we can start rendering.
  g_signal_connect_swapped(view, "first-frame", G_CALLBACK(first_frame_cb),
                           self);
  gtk_widget_realize(GTK_WIDGET(view));

  fl_register_plugins(FL_PLUGIN_REGISTRY(view));

  // 注册剪贴板文件读取通道（不是插件，是应用自己的原生能力）。
  //
  // 时机放在 fl_register_plugins 之后：两者都需要从 FlView 的 engine 取
  // messenger，而 engine 在 fl_view_new 时就已建好，放在这里是为了与插件
  // 注册保持同一个「引擎已就绪」的前提，避免将来调整顺序时踩坑。
  //
  // 通道对象由 self 持有：messenger 内部也会 ref 它（直到通道关闭），但
  // 依赖那一层引用会让「通道是否还活着」变得不显式，自己持有一份更清楚。
  {
    g_autoptr(FlStandardMethodCodec) codec = fl_standard_method_codec_new();
    self->clipboard_channel = fl_method_channel_new(
        fl_engine_get_binary_messenger(fl_view_get_engine(view)),
        kClipboardFilesChannelName, FL_METHOD_CODEC(codec));
    fl_method_channel_set_method_call_handler(self->clipboard_channel,
                                              clipboard_method_call_cb,
                                              nullptr, nullptr);
  }

  gtk_widget_grab_focus(GTK_WIDGET(view));
}

// Implements GApplication::local_command_line.
static gboolean my_application_local_command_line(GApplication* application,
                                                  gchar*** arguments,
                                                  int* exit_status) {
  MyApplication* self = MY_APPLICATION(application);
  // Strip out the first argument as it is the binary name.
  self->dart_entrypoint_arguments = g_strdupv(*arguments + 1);

  g_autoptr(GError) error = nullptr;
  if (!g_application_register(application, nullptr, &error)) {
    g_warning("Failed to register: %s", error->message);
    *exit_status = 1;
    return TRUE;
  }

  g_application_activate(application);
  *exit_status = 0;

  return TRUE;
}

// Implements GApplication::startup.
static void my_application_startup(GApplication* application) {
  // MyApplication* self = MY_APPLICATION(object);

  // Perform any actions required at application startup.

  G_APPLICATION_CLASS(my_application_parent_class)->startup(application);
}

// Implements GApplication::shutdown.
static void my_application_shutdown(GApplication* application) {
  // MyApplication* self = MY_APPLICATION(object);

  // Perform any actions required at application shutdown.

  G_APPLICATION_CLASS(my_application_parent_class)->shutdown(application);
}

// Implements GObject::dispose.
static void my_application_dispose(GObject* object) {
  MyApplication* self = MY_APPLICATION(object);
  g_clear_pointer(&self->dart_entrypoint_arguments, g_strfreev);
  g_clear_object(&self->clipboard_channel);
  G_OBJECT_CLASS(my_application_parent_class)->dispose(object);
}

static void my_application_class_init(MyApplicationClass* klass) {
  G_APPLICATION_CLASS(klass)->activate = my_application_activate;
  G_APPLICATION_CLASS(klass)->local_command_line =
      my_application_local_command_line;
  G_APPLICATION_CLASS(klass)->startup = my_application_startup;
  G_APPLICATION_CLASS(klass)->shutdown = my_application_shutdown;
  G_OBJECT_CLASS(klass)->dispose = my_application_dispose;
}

static void my_application_init(MyApplication* self) {}

MyApplication* my_application_new() {
  // Set the program name to the application ID, which helps various systems
  // like GTK and desktop environments map this running application to its
  // corresponding .desktop file. This ensures better integration by allowing
  // the application to be recognized beyond its binary name.
  g_set_prgname(APPLICATION_ID);

  return MY_APPLICATION(g_object_new(my_application_get_type(),
                                     "application-id", APPLICATION_ID, "flags",
                                     G_APPLICATION_NON_UNIQUE, nullptr));
}
