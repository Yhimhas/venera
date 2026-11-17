import 'package:flutter/services.dart';
import 'package:venera/foundation/app.dart';
import 'package:venera/foundation/appdata.dart';
import 'package:venera/utils/ext.dart';

String? _cachedProxy;

DateTime? _cachedProxyTime;

/// Drops the cached proxy, so a changed setting takes effect immediately.
void resetProxyCache() {
  _cachedProxy = null;
  _cachedProxyTime = null;
}

Future<String?> getProxy() async {
  if (_cachedProxyTime != null &&
      DateTime.now().difference(_cachedProxyTime!).inSeconds < 1) {
    return _cachedProxy;
  }
  String? proxy = await _getProxy();
  _cachedProxy = proxy;
  _cachedProxyTime = DateTime.now();
  return proxy;
}

Future<String?> _getProxy() async {
  if ((appdata.settings['proxy'] as String).removeAllBlank == "direct") {
    return null;
  }
  if (appdata.settings['proxy'] != "system") {
    return normalizeProxy(appdata.settings['proxy']);
  }

  String res;
  if (!App.isLinux) {
    const channel = MethodChannel("venera/method_channel");
    try {
      res = await channel.invokeMethod("getProxy");
    } catch (e) {
      return null;
    }
  } else {
    res = "No Proxy";
  }
  if (res == "No Proxy") return null;

  if (res.contains(";")) {
    var proxies = res.split(";");
    for (String proxy in proxies) {
      proxy = proxy.removeAllBlank;
      if (proxy.startsWith('https=')) {
        return normalizeProxy(proxy.substring(6));
      }
    }
  }

  final RegExp regex = RegExp(
    r'^\d{1,3}\.\d{1,3}\.\d{1,3}\.\d{1,3}:\d+$',
    caseSensitive: false,
    multiLine: false,
  );
  if (!regex.hasMatch(res)) {
    return null;
  }

  return normalizeProxy(res);
}

/// Supported proxy schemes.
const supportedProxySchemes = ['http', 'https', 'socks5'];

/// Coerce a proxy string into a url understood by rhttp.
///
/// `HOST:PORT` (the old format) is treated as a http proxy, so existing
/// settings keep working.
String? normalizeProxy(String? proxy) {
  if (proxy == null) return null;
  var value = proxy.removeAllBlank;
  if (value.isEmpty) return null;
  final lower = value.toLowerCase();
  for (final scheme in supportedProxySchemes) {
    if (lower.startsWith('$scheme://')) {
      return value;
    }
  }
  if (lower.startsWith('socks5h://')) {
    return value;
  }
  return 'http://$value';
}
