import 'package:flutter/material.dart';

import 'theme.dart';
import 'ui.dart';

/// A source plugin's filters or settings, as the plugin defines them
/// (LNReader's filter and setting types): each a label, a type and, for a
/// choice, its options. Pops the values chosen, by key.
///
/// Types: Text; Picker or Select (one option); Checkbox or CheckboxGroup
/// (several); XCheckbox (several, each in or out: {include, exclude});
/// Switch (on or off).
class PluginOptionsSheet extends StatefulWidget {
  const PluginOptionsSheet({
    super.key,
    required this.title,
    required this.definitions,
    required this.values,
    required this.action,
  });

  final String title;
  final Map<String, Object?> definitions;
  final Map<String, Object?> values;

  /// The button that takes them ("Show", "Save").
  final String action;

  @override
  State<PluginOptionsSheet> createState() => _PluginOptionsSheetState();
}

class _PluginOptionsSheetState extends State<PluginOptionsSheet> {
  late final _values = <String, Object?>{...widget.values};
  final _texts = <String, TextEditingController>{};

  @override
  void dispose() {
    for (final c in _texts.values) {
      c.dispose();
    }
    super.dispose();
  }

  static List<(String, String)> _options(Map def) => [
        for (final o in def['options'] as List? ?? const [])
          if (o is Map) ('${o['label'] ?? o['value']}', '${o['value']}'),
      ];

  Widget _field(String key, Map def) {
    final label = '${def['label'] ?? key}';
    final type = '${def['type'] ?? 'Text'}';
    final value = _values[key];
    final heading = Padding(
      padding: const EdgeInsets.only(top: Gap.l, bottom: Gap.s),
      child: Text(label, style: Skin.label(context, size: 14)),
    );
    switch (type) {
      case 'Switch':
        return SwitchListTile(
          contentPadding: EdgeInsets.zero,
          title: Text(label),
          value: value == true,
          onChanged: (v) => setState(() => _values[key] = v),
        );
      case 'Picker' || 'Select':
        final options = _options(def);
        return Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            heading,
            Wrap(spacing: Gap.s, runSpacing: Gap.s, children: [
              for (final (text, v) in options)
                ChoiceChip(
                  label: Text(text),
                  selected: '$value' == v,
                  onSelected: (_) => setState(() => _values[key] = v),
                ),
            ]),
          ],
        );
      case 'Checkbox' || 'CheckboxGroup':
        final chosen = {for (final v in value is List ? value : const []) '$v'};
        return Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            heading,
            Wrap(spacing: Gap.s, runSpacing: Gap.s, children: [
              for (final (text, v) in _options(def))
                FilterChip(
                  label: Text(text),
                  selected: chosen.contains(v),
                  onSelected: (on) => setState(() => _values[key] = [
                        for (final x in chosen)
                          if (x != v) x,
                        if (on) v,
                      ]),
                ),
            ]),
          ],
        );
      case 'XCheckbox':
        // Each option in, out, or neither: a tap moves it on.
        final m = value is Map ? value : const {};
        final include = {for (final v in m['include'] as List? ?? const []) '$v'};
        final exclude = {for (final v in m['exclude'] as List? ?? const []) '$v'};
        return Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            heading,
            Wrap(spacing: Gap.s, runSpacing: Gap.s, children: [
              for (final (text, v) in _options(def))
                FilterChip(
                  label: Text(exclude.contains(v) ? 'Not $text' : text),
                  selected: include.contains(v) || exclude.contains(v),
                  avatar: exclude.contains(v) ? const Icon(Icons.block_rounded, size: 16) : null,
                  showCheckmark: include.contains(v),
                  onSelected: (_) => setState(() {
                    final inc = {...include}, exc = {...exclude};
                    if (inc.remove(v)) {
                      exc.add(v);
                    } else if (!exc.remove(v)) {
                      inc.add(v);
                    }
                    _values[key] = {'include': inc.toList(), 'exclude': exc.toList()};
                  }),
                ),
            ]),
          ],
        );
      default:
        final c = _texts.putIfAbsent(key, () => TextEditingController(text: value == null ? '' : '$value'));
        return Padding(
          padding: const EdgeInsets.only(top: Gap.m),
          child: TextField(
            controller: c,
            decoration: InputDecoration(labelText: label),
            onChanged: (v) => _values[key] = v,
          ),
        );
    }
  }

  @override
  Widget build(BuildContext context) {
    final defs = [
      for (final e in widget.definitions.entries)
        if (e.value is Map) (e.key, e.value as Map),
    ];
    return SafeArea(
      child: Padding(
        padding: EdgeInsets.only(bottom: MediaQuery.viewInsetsOf(context).bottom),
        child: ConstrainedBox(
          constraints: BoxConstraints(maxHeight: MediaQuery.sizeOf(context).height * 0.85),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              const SizedBox(height: Gap.l),
              SheetHeader(widget.title),
              Flexible(
                child: ListView(
                  shrinkWrap: true,
                  padding: const EdgeInsets.symmetric(horizontal: Gap.xl),
                  children: [for (final (key, def) in defs) _field(key, def)],
                ),
              ),
              Padding(
                padding: const EdgeInsets.fromLTRB(Gap.xl, Gap.l, Gap.xl, Gap.l),
                child: FilledButton(
                  onPressed: () => Navigator.of(context).pop(_values),
                  child: Text(widget.action),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
