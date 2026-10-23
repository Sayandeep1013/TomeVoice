import 'package:flutter/material.dart';

import 'theme.dart';

/// The shared pieces every screen is built from. Each exists once, so a
/// search box, a setting or a choice looks the same wherever it appears.

/// A section heading in Bodoni, with an optional quiet note on the right.
class SectionTitle extends StatelessWidget {
  const SectionTitle(this.text, {super.key, this.note, this.size = 21});

  final String text;
  final String? note;
  final double size;

  @override
  Widget build(BuildContext context) => Row(
        crossAxisAlignment: CrossAxisAlignment.baseline,
        textBaseline: TextBaseline.alphabetic,
        children: [
          Expanded(child: Text(text, style: Skin.title(context, size: size))),
          if (note != null)
            Text(note!.toUpperCase(), style: Skin.meta(context)),
        ],
      );
}

/// An uppercase label above a group ("CONTINUE", "READING").
class Eyebrow extends StatelessWidget {
  const Eyebrow(this.text, {super.key, this.color});

  final String text;
  final Color? color;

  @override
  Widget build(BuildContext context) =>
      Text(text.toUpperCase(), style: Skin.meta(context, color: color));
}

/// A small outlined fact: "EPUB", "ENGLISH", "2 H 45 M".
class TagChip extends StatelessWidget {
  const TagChip(this.label, {super.key, this.accent = false});

  final String label;
  final bool accent;

  @override
  Widget build(BuildContext context) {
    final color = accent ? Skin.amber : Skin.inkFaintOn(context);
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 1),
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(Radii.pill),
        border: Border.all(color: color.withValues(alpha: accent ? 0.8 : 0.45)),
      ),
      child: Text(label.toUpperCase(), style: Skin.meta(context, size: 10, color: color)),
    );
  }
}

/// A thin rounded progress bar.
class Progress extends StatelessWidget {
  const Progress(this.value, {super.key, this.height = 3, this.track});

  final double value;
  final double height;
  final Color? track;

  @override
  Widget build(BuildContext context) => ClipRRect(
        borderRadius: BorderRadius.circular(height),
        child: LinearProgressIndicator(
          value: value.clamp(0.0, 1.0),
          minHeight: height,
          color: Skin.amber,
          backgroundColor: track ?? Skin.inkOn(context).withValues(alpha: 0.12),
        ),
      );
}

/// One choice among a few, as a single row of segments. Falls back to a
/// scrolling row of pills when the options do not fit, so nothing ever wraps
/// onto a second line.
class ChoiceRow<T> extends StatelessWidget {
  const ChoiceRow({
    super.key,
    required this.options,
    required this.value,
    required this.onChanged,
    this.minSegment = 62,
  });

  final List<(T, String)> options;
  final T? value;
  final ValueChanged<T> onChanged;
  final double minSegment;

  @override
  Widget build(BuildContext context) => LayoutBuilder(
        builder: (context, c) {
          final fits = c.maxWidth >= options.length * minSegment;
          final segments = [
            for (final (v, label) in options)
              _Segment(
                label: label,
                selected: v == value,
                onTap: () => onChanged(v),
                expand: fits,
              ),
          ];
          final track = Container(
            padding: const EdgeInsets.all(3),
            decoration: BoxDecoration(
              color: Skin.raisedOn(context),
              borderRadius: BorderRadius.circular(Radii.pill),
            ),
            child: Row(
              mainAxisSize: fits ? MainAxisSize.max : MainAxisSize.min,
              children: segments,
            ),
          );
          return fits
              ? track
              : SingleChildScrollView(scrollDirection: Axis.horizontal, child: track);
        },
      );
}

class _Segment extends StatelessWidget {
  const _Segment({
    required this.label,
    required this.selected,
    required this.onTap,
    required this.expand,
  });

  final String label;
  final bool selected;
  final VoidCallback onTap;
  final bool expand;

  @override
  Widget build(BuildContext context) {
    final body = Semantics(
      selected: selected,
      button: true,
      child: Material(
        color: selected ? Skin.amber : Colors.transparent,
        borderRadius: BorderRadius.circular(Radii.pill),
        child: InkWell(
          borderRadius: BorderRadius.circular(Radii.pill),
          onTap: onTap,
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: Gap.m, vertical: 9),
            child: Text(
              label,
              textAlign: TextAlign.center,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: Skin.ui(
                size: 13.5,
                weight: selected ? FontWeight.w700 : FontWeight.w500,
                color: selected ? Skin.onAmber : Skin.inkSoftOn(context),
              ),
            ),
          ),
        ),
      ),
    );
    return expand ? Expanded(child: body) : body;
  }
}

/// − value + : for speed and text size.
class StepperControl extends StatelessWidget {
  const StepperControl({
    super.key,
    required this.value,
    required this.onMinus,
    required this.onPlus,
    this.minusTooltip = 'Less',
    this.plusTooltip = 'More',
    this.valueStyle,
  });

  final String value;
  final VoidCallback? onMinus;
  final VoidCallback? onPlus;
  final String minusTooltip;
  final String plusTooltip;
  final TextStyle? valueStyle;

  @override
  Widget build(BuildContext context) => Row(
        children: [
          RoundButton(
            icon: Icons.remove_rounded,
            tooltip: minusTooltip,
            onTap: onMinus,
            color: Skin.raisedOn(context),
            iconColor: onMinus == null ? Skin.inkFaintOn(context) : Skin.inkOn(context),
          ),
          Expanded(
            child: Text(
              value,
              textAlign: TextAlign.center,
              style: valueStyle ??
                  Skin.ui(size: 22, weight: FontWeight.w700, color: Skin.inkOn(context), tabular: true),
            ),
          ),
          RoundButton(
            icon: Icons.add_rounded,
            tooltip: plusTooltip,
            onTap: onPlus,
            color: Skin.raisedOn(context),
            iconColor: onPlus == null ? Skin.inkFaintOn(context) : Skin.inkOn(context),
          ),
        ],
      );
}

/// A row in a settings list: title, optional detail, and whatever sits on
/// the right (a value, a switch, a chevron).
class SettingRow extends StatelessWidget {
  const SettingRow({
    super.key,
    required this.title,
    this.subtitle,
    this.value,
    this.icon,
    this.trailing,
    this.onTap,
  });

  final String title;
  final String? subtitle;
  final String? value;
  final IconData? icon;
  final Widget? trailing;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) => InkWell(
        onTap: onTap,
        child: ConstrainedBox(
          constraints: const BoxConstraints(minHeight: 56),
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: Gap.page, vertical: Gap.m),
            child: Row(
              children: [
                if (icon != null) ...[
                  Icon(icon, size: 22, color: Skin.inkSoftOn(context)),
                  const SizedBox(width: Gap.l),
                ],
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Text(title,
                          style: Skin.ui(size: 16, weight: FontWeight.w500, color: Skin.inkOn(context))),
                      if (subtitle != null) ...[
                        const SizedBox(height: 2),
                        Text(subtitle!,
                            style: Skin.ui(size: 13.5, weight: FontWeight.w400, color: Skin.inkFaintOn(context))),
                      ],
                    ],
                  ),
                ),
                if (value != null) ...[
                  const SizedBox(width: Gap.m),
                  Text(value!,
                      style: Skin.ui(
                          size: 14.5, weight: FontWeight.w600, color: Skin.inkSoftOn(context), tabular: true)),
                ],
                if (trailing != null) ...[const SizedBox(width: Gap.s), trailing!],
                if (trailing == null && onTap != null && value == null)
                  Icon(Icons.chevron_right_rounded, color: Skin.inkFaintOn(context)),
              ],
            ),
          ),
        ),
      );
}

/// A setting that is on or off.
class SwitchRow extends StatelessWidget {
  const SwitchRow({
    super.key,
    required this.title,
    this.subtitle,
    required this.value,
    required this.onChanged,
    this.padding = const EdgeInsets.symmetric(horizontal: Gap.page, vertical: Gap.s),
  });

  final String title;
  final String? subtitle;
  final bool value;
  final ValueChanged<bool> onChanged;
  final EdgeInsets padding;

  @override
  Widget build(BuildContext context) => InkWell(
        onTap: () => onChanged(!value),
        child: Padding(
          padding: padding,
          child: Row(
            children: [
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(title,
                        style: Skin.ui(size: 16, weight: FontWeight.w500, color: Skin.inkOn(context))),
                    if (subtitle != null)
                      Text(subtitle!,
                          style: Skin.ui(size: 13.5, weight: FontWeight.w400, color: Skin.inkFaintOn(context))),
                  ],
                ),
              ),
              Switch(value: value, onChanged: onChanged),
            ],
          ),
        ),
      );
}

/// The one search field.
class SearchField extends StatelessWidget {
  const SearchField({
    super.key,
    required this.hint,
    required this.onChanged,
    this.controller,
    this.autofocus = false,
    this.onClear,
  });

  final String hint;
  final ValueChanged<String> onChanged;
  final TextEditingController? controller;
  final bool autofocus;
  final VoidCallback? onClear;

  @override
  Widget build(BuildContext context) => TextField(
        controller: controller,
        autofocus: autofocus,
        style: Skin.ui(size: 15, weight: FontWeight.w500, color: Skin.inkOn(context)),
        textInputAction: TextInputAction.search,
        decoration: InputDecoration(
          prefixIcon: const Icon(Icons.search_rounded, size: 20),
          hintText: hint,
          suffixIcon: onClear == null
              ? null
              : IconButton(
                  tooltip: 'Clear',
                  icon: const Icon(Icons.close_rounded, size: 20),
                  onPressed: onClear,
                ),
        ),
        onChanged: onChanged,
      );
}

/// What a screen says when it has nothing to show yet.
class EmptyState extends StatelessWidget {
  const EmptyState({
    super.key,
    required this.icon,
    required this.title,
    required this.body,
    this.action,
  });

  final IconData icon;
  final String title;
  final String body;
  final Widget? action;

  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.symmetric(horizontal: Gap.xxl, vertical: Gap.xxl),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(icon, size: 40, color: Skin.amber.withValues(alpha: 0.85)),
            const SizedBox(height: Gap.l),
            Text(title, textAlign: TextAlign.center, style: Skin.title(context, size: 24)),
            const SizedBox(height: Gap.s),
            Text(
              body,
              textAlign: TextAlign.center,
              style: Skin.ui(size: 15, weight: FontWeight.w400, color: Skin.inkSoftOn(context))
                  .copyWith(height: 1.45),
            ),
            if (action != null) ...[const SizedBox(height: Gap.xl), action!],
          ],
        ),
      );
}

/// One action in a bottom sheet menu.
class SheetAction extends StatelessWidget {
  const SheetAction({
    super.key,
    required this.icon,
    required this.label,
    required this.onTap,
    this.danger = false,
    this.detail,
  });

  final IconData icon;
  final String label;
  final String? detail;
  final VoidCallback onTap;
  final bool danger;

  @override
  Widget build(BuildContext context) {
    final color = danger ? const Color(0xFFE5674D) : Skin.inkOn(context);
    return InkWell(
      onTap: onTap,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: Gap.xl, vertical: 14),
        child: Row(
          children: [
            Icon(icon, color: danger ? color : Skin.inkSoftOn(context), size: 22),
            const SizedBox(width: Gap.l),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(label, style: Skin.ui(size: 16, weight: FontWeight.w500, color: color)),
                  if (detail != null)
                    Text(detail!,
                        style: Skin.ui(size: 13, weight: FontWeight.w400, color: Skin.inkFaintOn(context))),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// A sheet's own heading, under the drag handle.
class SheetHeader extends StatelessWidget {
  const SheetHeader(this.title, {super.key, this.subtitle, this.trailing});

  final String title;
  final String? subtitle;
  final Widget? trailing;

  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.fromLTRB(Gap.xl, 0, Gap.xl, Gap.m),
        child: Row(
          children: [
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(title,
                      maxLines: 2, overflow: TextOverflow.ellipsis, style: Skin.title(context, size: 24)),
                  if (subtitle != null) ...[
                    const SizedBox(height: Gap.xs),
                    Text(subtitle!.toUpperCase(), style: Skin.meta(context)),
                  ],
                ],
              ),
            ),
            if (trailing != null) trailing!,
          ],
        ),
      );
}

/// A short message at the bottom of the screen, styled by the theme.
void showSnack(BuildContext context, String text, {bool long = false, double lift = 0}) {
  final messenger = ScaffoldMessenger.maybeOf(context);
  if (messenger == null) return;
  messenger
    ..hideCurrentSnackBar()
    ..showSnackBar(SnackBar(
      content: Text(text),
      // A margin is only allowed on a floating bar; say so here rather than
      // relying on the theme.
      behavior: SnackBarBehavior.floating,
      duration: Duration(seconds: long ? 8 : 3),
      margin: EdgeInsets.fromLTRB(Gap.l, 0, Gap.l, Gap.l + lift),
    ));
}

/// Ask for a short piece of text (a category name). Null if cancelled.
Future<String?> askText(
  BuildContext context, {
  required String title,
  String initial = '',
  String hint = '',
  String action = 'Save',
}) async {
  final controller = TextEditingController(text: initial);
  final result = await showDialog<String>(
    context: context,
    builder: (ctx) => AlertDialog(
      title: Text(title),
      content: TextField(
        controller: controller,
        autofocus: true,
        textCapitalization: TextCapitalization.sentences,
        style: Skin.ui(size: 16, weight: FontWeight.w500, color: Skin.inkOn(ctx)),
        decoration: InputDecoration(hintText: hint),
        onSubmitted: (v) => Navigator.pop(ctx, v),
      ),
      actions: [
        TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('Cancel')),
        TextButton(onPressed: () => Navigator.pop(ctx, controller.text), child: Text(action)),
      ],
    ),
  );
  controller.dispose();
  final trimmed = result?.trim();
  return trimmed == null || trimmed.isEmpty ? null : trimmed;
}

/// A yes/no question. True only if confirmed.
Future<bool> confirm(
  BuildContext context, {
  required String title,
  required String body,
  required String action,
}) async =>
    await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(title),
        content: Text(body),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Cancel')),
          TextButton(onPressed: () => Navigator.pop(ctx, true), child: Text(action)),
        ],
      ),
    ) ==
    true;

/// The top of a pushed screen: a round back button and the screen's title.
class ScreenTopBar extends StatelessWidget {
  const ScreenTopBar({super.key, required this.title, required this.onBack});

  final String title;
  final VoidCallback onBack;

  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.fromLTRB(Gap.m, Gap.s, Gap.page, Gap.m),
        child: Row(
          children: [
            RoundButton(icon: Icons.arrow_back_rounded, tooltip: 'Back', onTap: onBack),
            const SizedBox(width: Gap.m),
            Expanded(child: Text(title, style: Skin.title(context, size: 26, weight: FontWeight.w500))),
          ],
        ),
      );
}
