import 'dart:io' show InternetAddress;

/// 站点交给系统浏览器打开，不携带 App 凭证。拒绝服务间地址和非 HTTP 链接。
/// 内网部署只有在配置的 UFS 本身同源时才允许访问，避免把远端 loopback 当作用户设备。
Uri? resolveArchiveSiteUrl(String raw, {required String ufsBaseUrl}) {
  final base = Uri.tryParse(ufsBaseUrl);
  final parsed = Uri.tryParse(raw);
  if (base == null || parsed == null || raw.trim().isEmpty) return null;
  if (!['http', 'https'].contains(base.scheme) || base.host.isEmpty) {
    return null;
  }
  final uri = Uri.parse(base.origin).resolveUri(parsed);
  if (!['http', 'https'].contains(uri.scheme) ||
      uri.host.isEmpty ||
      uri.userInfo.isNotEmpty) {
    return null;
  }
  if (_isInternalHost(uri.host) && uri.origin != base.origin) return null;
  return uri;
}

bool _isInternalHost(String host) {
  final name = host.toLowerCase();
  if (name == 'localhost' ||
      name.endsWith('.localhost') ||
      name.endsWith('.local') ||
      name == 'host.docker.internal') {
    return true;
  }
  final ip = InternetAddress.tryParse(name);
  if (ip == null) return !name.contains('.');
  final bytes = ip.rawAddress;
  if (ip.isLoopback || ip.isLinkLocal) return true;
  if (bytes.length == 4) {
    return bytes[0] == 0 ||
        bytes[0] == 10 ||
        bytes[0] == 127 ||
        (bytes[0] == 172 && bytes[1] >= 16 && bytes[1] <= 31) ||
        (bytes[0] == 192 && bytes[1] == 168);
  }
  // IPv4-mapped IPv6 地址也需要按其真实 IPv4 边界判断。
  if (bytes.take(10).every((b) => b == 0) &&
      bytes[10] == 255 &&
      bytes[11] == 255) {
    return _isInternalHost(bytes.skip(12).join('.'));
  }
  return bytes.every((b) => b == 0) || (bytes[0] & 0xfe) == 0xfc;
}
