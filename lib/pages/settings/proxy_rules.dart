part of 'settings_page.dart';

class _ProxyRulesView extends StatefulWidget {
  const _ProxyRulesView();

  @override
  State<_ProxyRulesView> createState() => _ProxyRulesViewState();
}

class _ProxyRulesViewState extends State<_ProxyRulesView> {
  Future<void> _editRule(ProxyRuleScope scope, [String? match]) async {
    final result = await showDialog<(String, String)>(
      context: context,
      builder: (context) => _ProxyRuleDialog(scope: scope, match: match),
    );
    if (result == null || !mounted) return;
    final rules = readProxyRules(scope)..[result.$1] = result.$2;
    _saveRules(scope, rules);
  }

  void _saveRules(ProxyRuleScope scope, Map<String, String> rules) {
    setState(() => appdata.settings[scope.settingsKey] = rules);
    appdata.saveData();
  }

  List<Widget> _section(ProxyRuleScope scope, String title) {
    final rules = readProxyRules(scope);
    final sources = {
      for (final source in ComicSource.all()) source.key: source.name,
    };
    final entries = rules.entries.toList()
      ..sort((a, b) => a.key.compareTo(b.key));
    final canAdd =
        scope == ProxyRuleScope.domain ||
        sources.keys.any((key) => !rules.containsKey(key));
    return [
      ListTile(
        title: Text(title, style: Theme.of(context).textTheme.titleMedium),
        trailing: IconButton(
          onPressed: canAdd ? () => _editRule(scope) : null,
          icon: const Icon(Icons.add),
          tooltip: 'Add'.tl,
        ),
      ),
      for (final entry in entries)
        ListTile(
          title: Text(
            scope == ProxyRuleScope.source
                ? sources[entry.key] ?? entry.key
                : entry.key,
          ),
          subtitle: Text(_proxyLabel(entry.value)),
          onTap: () => _editRule(scope, entry.key),
          trailing: IconButton(
            onPressed: () {
              final updatedRules = readProxyRules(scope)..remove(entry.key);
              _saveRules(scope, updatedRules);
            },
            icon: const Icon(Icons.remove_circle_outline),
            tooltip: 'Remove'.tl,
          ),
        ),
    ];
  }

  String _proxyLabel(String proxy) {
    if (proxy == 'direct') return 'Direct'.tl;
    if (proxy == 'system') return 'System'.tl;
    final uri = Uri.tryParse(normalizeProxy(proxy) ?? '');
    if (uri == null || uri.host.isEmpty) return 'Manual'.tl;
    final address = Uri(
      scheme: uri.scheme,
      host: uri.host,
      port: uri.hasPort ? uri.port : null,
    );
    return address.toString();
  }

  @override
  Widget build(BuildContext context) {
    return PopUpWidgetScaffold(
      title: 'Proxy Rules'.tl,
      body: ListView(
        children: [
          Padding(
            padding: const EdgeInsets.all(16),
            child: Text(
              'Source rules take precedence over domain rules. Other requests use the global proxy.'
                  .tl,
            ),
          ),
          ..._section(ProxyRuleScope.source, 'Comic Source'.tl),
          const Divider(),
          ..._section(ProxyRuleScope.domain, 'Domain'.tl),
        ],
      ),
    );
  }
}

class _ProxyRuleDialog extends StatefulWidget {
  const _ProxyRuleDialog({required this.scope, this.match});

  final ProxyRuleScope scope;
  final String? match;

  @override
  State<_ProxyRuleDialog> createState() => _ProxyRuleDialogState();
}

class _ProxyRuleDialogState extends State<_ProxyRuleDialog> {
  final _form = GlobalKey<FormState>();
  late final _rules = readProxyRules(widget.scope);
  late String? _match = widget.match;
  late String _address = _rules[_match] ?? '';
  late String _mode = switch (_address) {
    'direct' => 'direct',
    'system' => 'system',
    _ => 'manual',
  };

  bool get _bySource => widget.scope == ProxyRuleScope.source;

  void _save() {
    if (_form.currentState?.validate() != true) return;
    final proxy = _mode == 'manual' ? normalizeProxy(_address)! : _mode;
    Navigator.pop(context, (_match!, proxy));
  }

  String? _validateAddress(String? value) {
    final address = value?.trim() ?? '';
    final uri = Uri.tryParse(normalizeProxy(address) ?? '');
    if (uri == null ||
        uri.host.isEmpty ||
        ![...supportedProxySchemes, 'socks5h'].contains(uri.scheme) ||
        RegExp(r'\s').hasMatch(address) ||
        (uri.path.isNotEmpty && uri.path != '/') ||
        uri.hasQuery ||
        uri.hasFragment ||
        (uri.hasPort && (uri.port < 1 || uri.port > 65535))) {
      return 'Enter a valid proxy URL'.tl;
    }
    return null;
  }

  @override
  Widget build(BuildContext context) {
    final sources = ComicSource.all();
    return AlertDialog(
      title: Text((widget.match == null ? 'Add' : 'Edit').tl),
      content: Form(
        key: _form,
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              if (widget.match != null)
                Text(
                  _bySource
                      ? ComicSource.find(widget.match!)?.name ?? widget.match!
                      : widget.match!,
                )
              else if (_bySource)
                DropdownButtonFormField<String>(
                  initialValue: _match,
                  isExpanded: true,
                  decoration: InputDecoration(labelText: 'Comic Source'.tl),
                  items: [
                    for (final source in sources)
                      if (!_rules.containsKey(source.key))
                        DropdownMenuItem(
                          value: source.key,
                          child: Text(source.name),
                        ),
                  ],
                  onChanged: (value) => _match = value,
                  validator: (value) =>
                      value == null ? 'Select a comic source'.tl : null,
                )
              else
                TextFormField(
                  decoration: InputDecoration(
                    labelText: 'Domain'.tl,
                    hintText: 'example.org',
                    helperText: 'Domain rules include subdomains.'.tl,
                  ),
                  keyboardType: TextInputType.url,
                  onChanged: (value) => _match = normalizeProxyDomain(value),
                  validator: (value) {
                    if (_match == null) return 'Enter a valid domain'.tl;
                    if (_rules.containsKey(_match)) {
                      return 'This domain already has a rule'.tl;
                    }
                    return null;
                  },
                ),
              const SizedBox(height: 12),
              DropdownButtonFormField<String>(
                initialValue: _mode,
                decoration: InputDecoration(labelText: 'Proxy'.tl),
                items: [
                  DropdownMenuItem(value: 'direct', child: Text('Direct'.tl)),
                  DropdownMenuItem(value: 'system', child: Text('System'.tl)),
                  DropdownMenuItem(value: 'manual', child: Text('Manual'.tl)),
                ],
                onChanged: (value) => setState(() => _mode = value!),
              ),
              if (_mode == 'manual')
                TextFormField(
                  initialValue: _address == 'direct' || _address == 'system'
                      ? ''
                      : _address,
                  decoration: InputDecoration(
                    labelText: 'Proxy URL'.tl,
                    hintText: 'socks5://127.0.0.1:1080',
                  ),
                  keyboardType: TextInputType.url,
                  onChanged: (value) => _address = value,
                  validator: _validateAddress,
                ),
            ],
          ),
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: Text('Cancel'.tl),
        ),
        FilledButton(onPressed: _save, child: Text('Save'.tl)),
      ],
    );
  }
}
