import 'dart:async';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart' show BoxHitTestResult, RenderProxyBox;

import 'theme.dart';

/// The shared pieces every screen is built from. Each exists once, so a
/// search box, a setting or a choice looks the same wherever it appears.

/// [child] laid out and drawn as it is, taking a tap anywhere in a band
/// [above] dp over it and [below] dp under it: a control drawn thinner than
/// a finger's 48 dp (a row of choices, a slider, a row of chips) reaches that
/// tall. Each tap in the band is tried on the child's middle line, at the
/// same place across, so a margin inside it counts too; one that finds
/// nothing there goes on to what is behind. The band must lie in the
/// parent's room (a parent passes on only a tap inside itself), and what is
/// laid out after the child (below it, in a column) is asked first, so it
/// keeps its own taps.
class TapBand extends SingleChildRenderObjectWidget {
  const TapBand({super.key, this.above = 0, this.below = 0, required super.child});

  final double above;
  final double below;

  @override
  RenderObject createRenderObject(BuildContext context) => _RenderTapBand(above, below);

  @override
  void updateRenderObject(BuildContext context, RenderObject renderObject) => (renderObject as _RenderTapBand)
    ..above = above
    ..below = below;
}

class _RenderTapBand extends RenderProxyBox {
  _RenderTapBand(this.above, this.below);

  double above;
  double below;

  @override
  bool hitTest(BoxHitTestResult result, {required Offset position}) {
    if (position.dx < 0 || position.dx >= size.width || position.dy < -above || position.dy >= size.height + below) {
      return false;
    }
    // A drag begun in the band keeps the same shift, so a slider follows
    // the finger across.
    final middle = Offset(position.dx, size.height / 2);
    return result.addWithPaintOffset(
      offset: position - middle,
      position: position,
      hitTest: (result, at) => super.hitTest(result, position: at),
    );
  }
}

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
    final color = accent ? Skin.accentOf(context) : Skin.inkFaintOn(context);
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
        // Moves to a new value instead of stepping to it.
        child: TweenAnimationBuilder<double>(
          tween: Tween(end: value.clamp(0.0, 1.0)),
          duration: Motion.of(context, Motion.standard),
          curve: Motion.out,
          builder: (context, v, _) => LinearProgressIndicator(
            value: v,
            minHeight: height,
            color: Skin.accentOf(context),
            backgroundColor: track ?? Skin.inkOn(context).withValues(alpha: 0.12),
          ),
        ),
      );
}

/// One choice among a few, as a single row of segments. Falls back to a
/// scrolling row of pills when the options do not fit, so nothing ever wraps
/// onto a second line. The highlight slides to the chosen segment.
class ChoiceRow<T> extends StatefulWidget {
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

  /// The narrowest a segment may be.
  final double minSegment;

  /// Width of [label] as a segment draws it, padding included.
  static double _segmentWidth(String label, TextScaler scale) {
    final painter = TextPainter(
      text: TextSpan(text: label, style: Skin.ui(size: 13.5, weight: FontWeight.w700)),
      textDirection: TextDirection.ltr,
      textScaler: scale,
      maxLines: 1,
    )..layout();
    return painter.width + Gap.m * 2 + 2;
  }

  @override
  State<ChoiceRow<T>> createState() => _ChoiceRowState<T>();
}

class _ChoiceRowState<T> extends State<ChoiceRow<T>> {
  /// Where the highlight last stood, so that when nothing is chosen (a
  /// speed between presets) it fades out where it was instead of jumping.
  int _last = 0;

  /// For a row that scrolls: brings the chosen segment into view.
  final _scroll = ScrollController();
  int? _shown;

  @override
  void dispose() {
    _scroll.dispose();
    super.dispose();
  }

  void _reveal(int index, double left, double width, double viewport) {
    if (_shown == index) return;
    final first = _shown == null;
    _shown = index;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || !_scroll.hasClients) return;
      final target = (left - (viewport - width) / 2).clamp(0.0, _scroll.position.maxScrollExtent);
      final d = Motion.of(context, Motion.standard);
      if (first || d == Duration.zero) {
        _scroll.jumpTo(target);
      } else {
        _scroll.animateTo(target, duration: d, curve: Motion.emphasized);
      }
    });
  }

  // The segments are drawn 32 dp tall in a 38 dp track: a tap across the
  // track, or a little past its edges, is the segment's under it, a finger's
  // 48 dp in all.
  @override
  Widget build(BuildContext context) => TapBand(
        above: _reach,
        below: _reach,
        child: LayoutBuilder(builder: _row),
      );

  Widget _row(BuildContext context, BoxConstraints c) {
    final options = widget.options;
    // Each segment as wide as its label needs (so "Newsreader" is not
    // cut to "Newsrea…" beside "Sans"), sharing out what is left over.
    final widths = [
      for (final (_, label) in options)
        ChoiceRow._segmentWidth(label, MediaQuery.textScalerOf(context)).clamp(widget.minSegment, 400.0),
    ];
    final needed = widths.fold<double>(6, (a, b) => a + b);
    final fits = needed <= c.maxWidth;
    // Where each segment is laid out, for the highlight behind it.
    final flexes = [for (final w in widths) w.round()];
    final flexSum = flexes.fold<int>(0, (a, b) => a + b);
    final spans = fits ? [for (final f in flexes) (c.maxWidth - 6) * f / flexSum] : widths;
    final selected = options.indexWhere((o) => o.$1 == widget.value);
    if (selected >= 0) _last = selected;
    final at = options.isEmpty ? 0 : _last.clamp(0, options.length - 1);
    final left = spans.take(at).fold<double>(0, (a, b) => a + b);
    final duration = Motion.of(context, Motion.standard);
    final segments = [
      for (var i = 0; i < options.length; i++)
        _Segment(
          label: options[i].$2,
          selected: i == selected,
          onTap: () => widget.onChanged(options[i].$1),
          flex: fits ? flexes[i] : null,
          width: fits ? null : widths[i],
        ),
    ];
    final track = Container(
      padding: const EdgeInsets.all(3),
      constraints: BoxConstraints(minWidth: c.maxWidth),
      // A row that scrolls has its ground on the window round it (below).
      decoration: BoxDecoration(
        color: fits ? Skin.raisedOn(context) : null,
        borderRadius: BorderRadius.circular(Radii.pill),
      ),
      child: Stack(
        children: [
          if (options.isNotEmpty)
            AnimatedPositioned(
              duration: duration,
              curve: Motion.emphasized,
              left: left,
              width: spans[at],
              top: 0,
              bottom: 0,
              child: AnimatedOpacity(
                opacity: selected >= 0 ? 1 : 0,
                duration: duration,
                curve: Motion.out,
                child: DecoratedBox(
                  decoration: BoxDecoration(
                    color: Skin.accentOf(context),
                    borderRadius: BorderRadius.circular(Radii.pill),
                  ),
                ),
              ),
            ),
          Row(
            mainAxisSize: fits ? MainAxisSize.max : MainAxisSize.min,
            children: segments,
          ),
        ],
      ),
    );
    if (fits) return track;
    if (selected >= 0) _reveal(selected, left, spans[at], c.maxWidth);
    // Too many to fit: the segments scroll inside a pill that stays
    // put (scrolling the pill itself cut its ends off square), and fade
    // at the edge so it is plainly more than what shows.
    return ClipRRect(
      borderRadius: BorderRadius.circular(Radii.pill),
      child: ColoredBox(
        color: Skin.raisedOn(context),
        child: ShaderMask(
          blendMode: BlendMode.dstIn,
          shaderCallback: (rect) => const LinearGradient(
            colors: [Colors.black, Colors.black, Colors.transparent],
            stops: [0, 0.88, 1],
          ).createShader(rect),
          child: SingleChildScrollView(controller: _scroll, scrollDirection: Axis.horizontal, child: track),
        ),
      ),
    );
  }

  /// How far past the track's edges a tap still picks a segment.
  static const _reach = 5.0;
}

class _Segment extends StatelessWidget {
  const _Segment({
    required this.label,
    required this.selected,
    required this.onTap,
    this.flex,
    this.width,
  });

  final String label;
  final bool selected;
  final VoidCallback onTap;

  /// Share of the row when the segments fill it; null when it scrolls.
  final int? flex;

  /// Width when the row scrolls, so the highlight knows where it is.
  final double? width;

  @override
  Widget build(BuildContext context) {
    // The fill is the highlight sliding behind the row; the label only
    // changes colour.
    final body = Semantics(
      selected: selected,
      button: true,
      child: Material(
        type: MaterialType.transparency,
        borderRadius: BorderRadius.circular(Radii.pill),
        child: InkWell(
          borderRadius: BorderRadius.circular(Radii.pill),
          onTap: onTap,
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: Gap.m, vertical: 9),
            child: AnimatedDefaultTextStyle(
              duration: Motion.of(context, Motion.standard),
              curve: Motion.out,
              style: Skin.ui(
                size: 13.5,
                weight: selected ? FontWeight.w700 : FontWeight.w500,
                color: selected ? Skin.onAccentOf(context) : Skin.inkSoftOn(context),
              ),
              child: Text(
                label,
                textAlign: TextAlign.center,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
              ),
            ),
          ),
        ),
      ),
    );
    if (flex != null) return Expanded(flex: flex!, child: body);
    return width == null ? body : SizedBox(width: width, child: body);
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
            // The new value rises into place as the old one leaves.
            child: AnimatedSwitcher(
              duration: Motion.of(context, Motion.quick),
              switchInCurve: Motion.out,
              switchOutCurve: const Interval(0.5, 1),
              transitionBuilder: fadeRise,
              child: Text(
                value,
                key: ValueKey((value, valueStyle?.fontSize, valueStyle?.fontFamily)),
                textAlign: TextAlign.center,
                style: valueStyle ??
                    Skin.ui(size: 22, weight: FontWeight.w700, color: Skin.inkOn(context), tabular: true),
              ),
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
            Icon(icon, size: 40, color: Skin.accentOf(context).withValues(alpha: 0.85)),
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
/// [margin], when given, is where it floats instead of [lift] above the foot
/// (over a screen whose own controls are elsewhere than the reader's).
void showSnack(
  BuildContext context,
  String text, {
  bool long = false,
  double lift = 0,
  EdgeInsets? margin,
  String? actionLabel,
  VoidCallback? onAction,
}) {
  final messenger = ScaffoldMessenger.maybeOf(context);
  if (messenger == null) return;
  messenger
    ..hideCurrentSnackBar()
    ..showSnackBar(SnackBar(
      content: Text(text),
      action: actionLabel == null || onAction == null
          ? null
          : SnackBarAction(label: actionLabel, onPressed: onAction),
      // A margin is only allowed on a floating bar; say so here rather than
      // relying on the theme.
      behavior: SnackBarBehavior.floating,
      // A message with a button (Undo) would otherwise stay until dismissed.
      persist: false,
      duration: Duration(seconds: long ? 8 : (onAction == null ? 3 : 4)),
      margin: margin ?? EdgeInsets.fromLTRB(Gap.l, 0, Gap.l, Gap.l + lift),
    ));
}

/// The ground drawn once more over the [top] edge of a scrolling list (or
/// its foot), fading out away from the edge: the list fades into the ground
/// as it did under a mask over all of it, which cost an offscreen pass of
/// the whole list on every frame it moved; this costs only the strip.
///
/// [ground] is the ground as it is laid under the list, at [size], and
/// [link] is a [CompositedTransformTarget] around the real one: the copy is
/// drawn where that is, so a diagonal or vignetted ground meets itself with
/// no seam (a painted band of one colour never matched it, and read as a
/// bar).
class GroundFade extends StatelessWidget {
  const GroundFade({super.key, required this.link, required this.size, required this.ground, this.top = false});

  final LayerLink link;
  final Size size;
  final Widget ground;
  final bool top;

  @override
  Widget build(BuildContext context) => IgnorePointer(
        child: ShaderMask(
          blendMode: BlendMode.dstIn,
          shaderCallback: (rect) => LinearGradient(
            begin: Alignment.topCenter,
            end: Alignment.bottomCenter,
            colors: top ? const [Colors.black, Colors.transparent] : const [Colors.transparent, Colors.black],
          ).createShader(rect),
          // Clipped to the strip: the copy is the whole ground.
          child: ClipRect(
            child: CompositedTransformFollower(
              link: link,
              showWhenUnlinked: false,
              child: OverflowBox(
                alignment: Alignment.topLeft,
                minWidth: size.width,
                maxWidth: size.width,
                minHeight: size.height,
                maxHeight: size.height,
                child: ground,
              ),
            ),
          ),
        ),
      );
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
    animationStyle: sheetMotion(context),
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
      animationStyle: sheetMotion(context),
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

// ---- motion --------------------------------------------------------------

/// How a bottom sheet or a dialog comes and goes, the same everywhere: in at
/// the pace of a screen arriving and settling as it lands, away a little
/// quicker. At once when the phone is set to remove animations. For
/// showModalBottomSheet's sheetAnimationStyle and showDialog's
/// animationStyle.
AnimationStyle sheetMotion(BuildContext context) => Motion.reduced(context)
    ? AnimationStyle.noAnimation
    : const AnimationStyle(
        duration: Motion.page,
        reverseDuration: Motion.standard,
        curve: Motion.out,
        reverseCurve: Motion.out,
      );

/// [child] fading in (and settling from a touch smaller) when it first
/// shows, and again whenever [trigger] changes, without being rebuilt: a new
/// screen in the same place arrives the way a pushed one does.
class FadeIn extends StatefulWidget {
  const FadeIn({super.key, this.trigger, this.arrive = true, required this.child});

  final Object? trigger;

  /// False: shown as it is at first, fading in only when [trigger] changes
  /// (for something whose arrival is already faded by what holds it).
  final bool arrive;

  final Widget child;

  @override
  State<FadeIn> createState() => _FadeInState();
}

class _FadeInState extends State<FadeIn> with SingleTickerProviderStateMixin {
  late final _controller =
      AnimationController(vsync: this, duration: Motion.page, value: widget.arrive ? 0 : 1);
  late final _t = CurvedAnimation(parent: _controller, curve: Motion.out);

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (Motion.reduced(context)) {
      _controller.value = 1;
    } else if (_controller.status == AnimationStatus.dismissed) {
      _controller.forward();
    }
  }

  @override
  void didUpdateWidget(FadeIn old) {
    super.didUpdateWidget(old);
    if (old.trigger != widget.trigger && !Motion.reduced(context)) _controller.forward(from: 0);
  }

  @override
  void dispose() {
    _t.dispose();
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => FadeTransition(
        opacity: _t,
        child: ScaleTransition(scale: Tween(begin: 0.98, end: 1.0).animate(_t), child: widget.child),
      );
}

/// A sliver fading in when it first shows: a list taking the place of a
/// spinner arrives instead of snapping in.
class SliverFadeIn extends StatefulWidget {
  const SliverFadeIn({super.key, required this.sliver});

  final Widget sliver;

  @override
  State<SliverFadeIn> createState() => _SliverFadeInState();
}

class _SliverFadeInState extends State<SliverFadeIn> with SingleTickerProviderStateMixin {
  late final _controller = AnimationController(vsync: this, duration: Motion.page);
  late final _t = CurvedAnimation(parent: _controller, curve: Motion.out);

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (Motion.reduced(context)) {
      _controller.value = 1;
    } else if (_controller.status == AnimationStatus.dismissed) {
      _controller.forward();
    }
  }

  @override
  void dispose() {
    _t.dispose();
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => SliverFadeTransition(opacity: _t, sliver: widget.sliver);
}

/// Room for [child] that opens and closes smoothly as it comes and goes
/// (null: nothing), the child fading in as it does, instead of pushing what
/// is below it down in one jump.
Widget growIn(BuildContext context, Widget? child) => AnimatedSize(
      duration: Motion.of(context, Motion.standard),
      curve: Motion.out,
      alignment: Alignment.topCenter,
      child: child == null ? const SizedBox(width: double.infinity) : FadeIn(child: child),
    );

/// A row that folds shut, fading, when [open] turns false, and opens again
/// when it turns true; with [appear], it also opens from nothing when it is
/// first built. What is below moves up or down with it instead of jumping.
class Fold extends StatelessWidget {
  const Fold({super.key, this.open = true, this.appear = false, required this.child});

  final bool open;
  final bool appear;
  final Widget child;

  @override
  Widget build(BuildContext context) => TweenAnimationBuilder<double>(
        tween: Tween(begin: appear ? 0 : 1, end: open ? 1 : 0),
        duration: Motion.of(context, Motion.standard),
        curve: Motion.out,
        child: child,
        // The same widgets at rest as in motion, so the row keeps its state.
        builder: (context, t, child) => ClipRect(
          child: Align(
            alignment: Alignment.topCenter,
            heightFactor: t,
            child: Opacity(opacity: t, child: child),
          ),
        ),
      );
}

/// An [Image.frameBuilder] that fades the picture in over [under] (what shows
/// while it decodes) instead of popping over it; one already in memory shows
/// at once.
ImageFrameBuilder fadeInOver(Widget under) => (context, child, frame, sync) {
      if (sync) return child;
      return Stack(
        fit: StackFit.passthrough,
        children: [
          under,
          AnimatedOpacity(
            opacity: frame == null ? 0 : 1,
            duration: Motion.of(context, Motion.standard),
            curve: Motion.out,
            child: child,
          ),
        ],
      );
    };

/// One state of a screen giving way to another in the same room (nothing
/// yet, the results, the list): the two cross-fade, each filling the room,
/// instead of one cutting to the other. Give each state its own key; one
/// with the same key is only rebuilt, keeping its scroll and its state.
/// [instant]: this change is not shown (the first state after nothing, while
/// the whole screen is already fading in).
Widget fadeSwitch(BuildContext context, Widget child, {bool instant = false}) => AnimatedSwitcher(
      duration: instant ? Duration.zero : Motion.of(context, Motion.standard),
      switchInCurve: Motion.out,
      switchOutCurve: Motion.out,
      layoutBuilder: (current, previous) => Stack(
        fit: StackFit.expand,
        children: [...previous, if (current != null) current],
      ),
      child: child,
    );

/// An [AnimatedSwitcher] transition: the new child fades in while rising a
/// little; the old one fades out the same way.
Widget fadeRise(Widget child, Animation<double> animation) => FadeTransition(
      opacity: animation,
      child: SlideTransition(
        position: animation.drive(Tween(begin: const Offset(0, 0.15), end: Offset.zero)),
        child: child,
      ),
    );

/// An [AnimatedSwitcher] transition for something that opens below what is
/// above it (a search field, a progress card): it unfolds downwards and
/// fades in, and folds away the same way.
Widget revealDown(Widget child, Animation<double> animation) =>
    FadeTransition(opacity: animation, child: _Reveal(animation: animation, child: child));

class _Reveal extends AnimatedWidget {
  const _Reveal({required Animation<double> animation, required this.child}) : super(listenable: animation);

  final Widget child;

  @override
  Widget build(BuildContext context) => ClipRect(
        child: Align(
          alignment: Alignment.topCenter,
          heightFactor: (listenable as Animation<double>).value.clamp(0.0, 1.0),
          child: child,
        ),
      );
}

/// Fades and lifts [child] into place the first time a list shows, each row
/// a beat after the one before. A row built later (scrolled to, or rebuilt)
/// is simply there: lists do not animate while you scroll them.
class Entrance extends StatefulWidget {
  const Entrance({super.key, required this.index, required this.since, required this.child});

  /// The row's place in the list.
  final int index;

  /// When the list first showed; null for no entrance at all.
  final DateTime? since;

  final Widget child;

  /// Rows built more than this after [since] are being scrolled to.
  static const window = Duration(milliseconds: 400);

  @override
  State<Entrance> createState() => _EntranceState();
}

class _EntranceState extends State<Entrance> with SingleTickerProviderStateMixin {
  AnimationController? _controller;
  CurvedAnimation? _curve;
  Animation<double> get _t => _curve ?? kAlwaysCompleteAnimation;

  @override
  void initState() {
    super.initState();
    final since = widget.since;
    if (since == null || DateTime.now().difference(since) > Entrance.window) return;
    // At most eight beats, so a long list does not keep the last rows waiting.
    final delay = 35.0 * widget.index.clamp(0, 8);
    final total = delay + Motion.page.inMilliseconds;
    final controller = AnimationController(vsync: this, duration: Duration(milliseconds: total.round()));
    _controller = controller;
    _curve = CurvedAnimation(parent: controller, curve: Interval(delay / total, 1, curve: Motion.out));
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final controller = _controller;
    if (controller == null || controller.isAnimating || controller.isCompleted) return;
    if (Motion.reduced(context)) {
      controller.value = 1;
    } else {
      controller.forward();
    }
  }

  @override
  void dispose() {
    _curve?.dispose();
    _controller?.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    // A row with no entrance gets no layers either: most rows are these.
    if (_controller == null) return widget.child;
    return FadeTransition(
      opacity: _t,
      child: AnimatedBuilder(
        animation: _t,
        child: widget.child,
        builder: (context, child) => Transform.translate(offset: Offset(0, 14 * (1 - _t.value)), child: child),
      ),
    );
  }
}

/// For a screen that follows something changing often while another screen
/// covers it (the reader saves its place every second or so): work handed
/// to [whenShown] is done at once while the screen shows, and otherwise
/// kept, once, for when the screen above has gone. Nothing is rebuilt
/// behind the reader, and nothing while it leaves.
///
/// The screen puts [shownGate] round what its build returns.
mixin WhenShown<T extends StatefulWidget> on State<T> {
  final _owed = <VoidCallback>{};
  ModalRoute<Object?>? _route;
  Animation<double>? _leaving;

  /// Whether nothing covers this screen: its route is the top one, and no
  /// screen above it is still on its way out.
  bool get shown {
    final route = _route;
    return route == null || (route.isCurrent && (route.secondaryAnimation?.isDismissed ?? true));
  }

  /// [work] now if the screen shows, else once it does.
  void whenShown(VoidCallback work) {
    if (shown) {
      work();
    } else {
      _owed.add(work);
    }
  }

  /// Done once this screen has finished arriving (at once if it has, or is
  /// leaving). Heavy content put in place while the screen still slides in
  /// (a book's whole chapter list) made the transition stutter.
  Future<void> arrived() {
    final arriving = _route?.animation;
    if (arriving == null || arriving.status != AnimationStatus.forward) return Future.value();
    final done = Completer<void>();
    void settled(AnimationStatus status) {
      if (status == AnimationStatus.forward) return;
      arriving.removeStatusListener(settled);
      done.complete();
    }

    arriving.addStatusListener(settled);
    return done.future;
  }

  /// [child], watching this screen's route. Only this small widget hears
  /// the route change, so the screen is not rebuilt when one is pushed.
  Widget shownGate(Widget child) => _RouteWatch(onRoute: _onRoute, child: child);

  void _onRoute(ModalRoute<Object?>? route) {
    _route = route;
    if (_owed.isEmpty || route == null || !route.isCurrent) return;
    // The screen above is going: catch up once it has gone, so the work
    // does not land in the frames of its transition.
    final leaving = route.secondaryAnimation;
    if (leaving == null || leaving.isDismissed) {
      WidgetsBinding.instance.addPostFrameCallback((_) => _pay());
    } else {
      _leaving ??= leaving..addStatusListener(_onLeaving);
    }
  }

  void _onLeaving(AnimationStatus status) {
    if (!status.isDismissed) return;
    _stopWatching();
    _pay();
  }

  void _stopWatching() {
    _leaving?.removeStatusListener(_onLeaving);
    _leaving = null;
  }

  void _pay() {
    if (!mounted || !shown || _owed.isEmpty) return;
    final work = [..._owed];
    _owed.clear();
    for (final w in work) {
      w();
    }
  }

  @override
  void dispose() {
    _stopWatching();
    super.dispose();
  }
}

class _RouteWatch extends StatefulWidget {
  const _RouteWatch({required this.onRoute, required this.child});

  final ValueChanged<ModalRoute<Object?>?> onRoute;
  final Widget child;

  @override
  State<_RouteWatch> createState() => _RouteWatchState();
}

class _RouteWatchState extends State<_RouteWatch> {
  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    // Called again whenever the route stops or starts being the top one.
    widget.onRoute(ModalRoute.of(context));
  }

  @override
  Widget build(BuildContext context) => widget.child;
}

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

/// A page's top bar ([child]) that stays put while the page scrolls under it:
/// a long chapter list used to carry Back, Search and the menu off the top.
/// Once something slides beneath, the bar frosts over so they stay legible.
class PinnedBar extends StatelessWidget {
  const PinnedBar({super.key, required this.child});

  final Widget child;

  /// The round buttons (44) with a little room above and below.
  static const height = Gap.s + 44 + Gap.s;

  @override
  Widget build(BuildContext context) => SliverPersistentHeader(pinned: true, delegate: _PinnedBarDelegate(child));
}

class _PinnedBarDelegate extends SliverPersistentHeaderDelegate {
  _PinnedBarDelegate(this.child);

  final Widget child;

  @override
  double get minExtent => PinnedBar.height;

  @override
  double get maxExtent => PinnedBar.height;

  @override
  Widget build(BuildContext context, double shrinkOffset, bool overlapsContent) {
    final under = overlapsContent || shrinkOffset > 0;
    return Stack(
      fit: StackFit.expand,
      children: [
        AnimatedOpacity(
          opacity: under ? 1 : 0,
          duration: Motion.of(context, Motion.standard),
          curve: Motion.out,
          child: ClipRect(
            child: BackdropFilter(
              filter: ui.ImageFilter.blur(sigmaX: 18, sigmaY: 18),
              child: ColoredBox(color: Skin.ground(context).colors.first.withValues(alpha: 0.78)),
            ),
          ),
        ),
        Align(alignment: Alignment.topCenter, child: child),
      ],
    );
  }

  @override
  bool shouldRebuild(_PinnedBarDelegate old) => old.child != child;
}
