import 'package:flutter/services.dart';
import 'package:venera/foundation/app.dart';
import 'package:venera/foundation/appdata.dart';
import 'package:venera/utils/ext.dart';

const proxySourceKey = 'venera.proxySourceKey';
const resolvedProxyKey = 'venera.resolvedProxy';

enum ProxyRuleScope {
  source('sourceProxies'),
  domain('domainProxies');

  const ProxyRuleScope(this.settingsKey);

  final String settingsKey;
}

Map<String, String> readProxyRules(ProxyRuleScope scope) {
  final rules = appdata.settings[scope.settingsKey];
  return rules is Map
      ? {
          for (final entry in rules.entries)
            if (entry.key is String && entry.value is String)
              entry.key as String: entry.value as String,
        }
      : {};
}

String? normalizeProxyDomain(String value) {
  final host = _normalizeHost(value.trim());
  final label = RegExp(r'^[a-z0-9](?:[a-z0-9-]{0,61}[a-z0-9])?$');
  if (host.length > 253 || !host.split('.').every(label.hasMatch)) {
    return null;
  }
  return host;
}

String _normalizeHost(String host) {
  host = host.toLowerCase();
  return host.endsWith('.') ? host.substring(0, host.length - 1) : host;
}

String? _cachedProxy;

DateTime? _cachedProxyTime;

/// Drops the cached proxy, so a changed setting takes effect immediately.
void resetProxyCache() {
  _cachedProxy = null;
  _cachedProxyTime = null;
}

Future<String?> getProxy({Uri? uri, String? sourceKey}) async {
  final sourceRules = appdata.settings[ProxyRuleScope.source.settingsKey];
  final domainRules = appdata.settings[ProxyRuleScope.domain.settingsKey];
  Object? proxy = sourceKey != null && sourceRules is Map
      ? sourceRules[sourceKey]
      : null;
  if (proxy is! String && uri != null && domainRules is Map) {
    // A rule covers its host and subdomains. Look up the longest match first.
    var host = _normalizeHost(uri.host);
    while (host.isNotEmpty) {
      proxy = domainRules[host];
      if (proxy is String) break;
      final dot = host.indexOf('.');
      if (dot < 0) break;
      host = host.substring(dot + 1);
    }
  }
  final setting = proxy is String ? proxy : appdata.settings['proxy'];
  if (setting is! String) return null;
  if (setting != 'system') {
    return setting.removeAllBlank == 'direct' ? null : normalizeProxy(setting);
  }

  if (_cachedProxyTime != null &&
      DateTime.now().difference(_cachedProxyTime!).inSeconds < 1) {
    return _cachedProxy;
  }
  final systemProxy = await _getSystemProxy();
  _cachedProxy = systemProxy;
  _cachedProxyTime = DateTime.now();
  return systemProxy;
}

Future<String?> _getSystemProxy() async {
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
