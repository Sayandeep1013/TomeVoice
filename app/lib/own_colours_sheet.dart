import 'package:flutter/material.dart';
import 'package:material_color_utilities/material_color_utilities.dart' show Hct;

import 'own_colours.dart';
import 'theme.dart';
import 'ui.dart';

/// Settings > Appearance > Your own: the reader's page, accent and text,
/// each picked from a row of swatches or on a hue and a shade, with a page
/// in those colours shown as it will read. The colours chosen, or null.
Future<OwnColours?> showOwnColours(BuildContext context, OwnColours start) => showModalBottomSheet<OwnColours>(
      context: context,
      sheetAnimationStyle: sheetMotion(context),
      isScrollControlled: true,
      useSafeArea: true,
      builder: (_) => OwnColoursSheet(start: start),
    );

/// The three colours a reader picks.
enum OwnPart {
  page('Page'),
  accent('Accent'),
  ink('Text');

  const OwnPart(this.label);

  final String label;
}

/// Good places to start, by part. The text's first is none: text made to
/// suit the page.
const ownSwatches = {
  OwnPart.page: [
    ('Paper', Color(0xFFF3EBDD)),
    ('White', Color(0xFFFBFAF6)),
    ('Mint', Color(0xFFD4E6D8)),
    ('Sky', Color(0xFFD6E4EE)),
    ('Lilac', Color(0xFFE6DFF2)),
    ('Rose', Color(0xFFF2E0E1)),
    ('Sand', Color(0xFFE9DAC1)),
    ('Forest', Color(0xFF16241C)),
    ('Slate', Color(0xFF283039)),
    ('Night', Color(0xFF141B2B)),
    ('Plum', Color(0xFF241B2A)),
    ('Black', Color(0xFF000000)),
  ],
  OwnPart.accent: [
    ('Amber', Color(0xFFE07B39)),
    ('Coral', Color(0xFFE8805E)),
    ('Red', Color(0xFFD64B3F)),
    ('Rose', Color(0xFFE05C8B)),
    ('Violet', Color(0xFF9B6CEB)),
    ('Indigo', Color(0xFF5D6FE8)),
    ('Blue', Color(0xFF3A8FDB)),
    ('Teal', Color(0xFF1FA39A)),
    ('Green', Color(0xFF4CA857)),
    ('Olive', Color(0xFF9AA33A)),
    ('Gold', Color(0xFFD9A62B)),
    ('Brown', Color(0xFF9A6A43)),
  ],
  OwnPart.ink: [
    ('Ink', Color(0xFF14170F)),
    ('Brown', Color(0xFF3B2B19)),
    ('Navy', Color(0xFF1D2840)),
    ('Plum', Color(0xFF3A2440)),
    ('Cream', Color(0xFFF2EADA)),
    ('White', Color(0xFFFFFFFF)),
    ('Stone', Color(0xFFB9B2A0)),
    ('Sand', Color(0xFFE8D9B8)),
  ],
};

class OwnColoursSheet extends StatefulWidget {
  const OwnColoursSheet({super.key, required this.start});

  final OwnColours start;

  @override
  State<OwnColoursSheet> createState() => _OwnColoursSheetState();
}

class _OwnColoursSheetState extends State<OwnColoursSheet> {
  late OwnColours _colours = widget.start;
  OwnPart _part = OwnPart.page;

  /// The colour of the part being picked; the text's as made when it is
  /// left to suit the page.
  Color _of(OwnPart part, OwnPalette made) => switch (part) {
        OwnPart.page => _colours.page,
        OwnPart.accent => _colours.accent,
        OwnPart.ink => _colours.ink ?? made.palette.inkFor(made.palette.only ?? Brightness.light),
      };

  void _set(Color? c) => setState(() => _colours = switch (_part) {
        OwnPart.page => _colours.withPage(c!),
        OwnPart.accent => _colours.withAccent(c!),
        OwnPart.ink => _colours.withInk(c),
      });

  /// Take the shades the colours were given to read as the reader's own.
  void _useShades(OwnPalette made) => setState(() {
        var c = _colours;
        if (made.page != null) c = c.withPage(made.page!);
        if (made.ink != null) c = c.withInk(made.ink);
        if (made.accent != null) c = c.withAccent(made.accent!);
        _colours = c;
      });

  @override
  Widget build(BuildContext context) {
    final made = _colours.made;
    final current = _of(_part, made);
    return SafeArea(
      child: SingleChildScrollView(
        padding: const EdgeInsets.fromLTRB(Gap.page, 0, Gap.page, Gap.xl),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text('Your own colours', style: Skin.title(context, size: 24)),
            const SizedBox(height: Gap.l),
            OwnPreview(palette: made.palette),
            if (made.adjusted) ...[
              const SizedBox(height: Gap.m),
              _Adjusted(made: made, chosen: _colours, onUse: () => _useShades(made)),
            ],
            const SizedBox(height: Gap.xl),
            ChoiceRow<OwnPart>(
              options: [for (final p in OwnPart.values) (p, p.label)],
              value: _part,
              onChanged: (p) => setState(() => _part = p),
            ),
            const SizedBox(height: Gap.l),
            _Swatches(
              part: _part,
              selected: _part == OwnPart.ink && _colours.ink == null ? null : current,
              onPick: _set,
            ),
            const SizedBox(height: Gap.l),
            HueShadePicker(
              colour: current,
              // A grey given a hue needs some colour to show it.
              minChroma: switch (_part) { OwnPart.page => 14, OwnPart.accent => 48, OwnPart.ink => 10 },
              onChanged: _set,
            ),
            const SizedBox(height: Gap.xl),
            FilledButton(
              onPressed: () => Navigator.of(context).pop(_colours),
              child: const Text('Use these colours'),
            ),
          ],
        ),
      ),
    );
  }
}

/// A page in [palette], as it will read: a chapter's label and title, a line
/// of the book, a row on a capsule, the accent as a button and as a link.
class OwnPreview extends StatelessWidget {
  const OwnPreview({super.key, required this.palette});

  final Palette palette;

  @override
  Widget build(BuildContext context) {
    final p = palette;
    final b = p.only ?? Skin.paletteOf(context).only ?? Theme.of(context).brightness;
    final dark = b == Brightness.dark;
    final ink = p.inkFor(b);
    final accentInk = dark ? p.accentSoft : p.accentDeep;
    final capsule = Color.alphaBlend(dark ? p.nightCapsule : p.dayCapsule, (dark ? p.night : p.day)[2]);
    return Semantics(
      label: 'How your colours will look',
      container: true,
      child: ExcludeSemantics(
        child: Container(
          padding: const EdgeInsets.all(Gap.l),
          decoration: BoxDecoration(
            gradient: Skin.groundFor(b, p),
            borderRadius: BorderRadius.circular(Radii.card),
            border: Border.all(color: Skin.outlineOn(context)),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text('CHAPTER 3 · 12 MIN LEFT', style: Skin.meta(context, color: p.inkFaintFor(b))),
              const SizedBox(height: Gap.xs),
              Text('The Garden Door', style: Skin.title(context, size: 22, color: accentInk)),
              const SizedBox(height: Gap.s),
              Text(
                'The rain had stopped, and the path shone all the way to the gate.',
                style: Skin.page(context, size: 16, height: 1.45).copyWith(color: ink),
              ),
              const SizedBox(height: Gap.m),
              Container(
                padding: const EdgeInsets.symmetric(horizontal: Gap.m, vertical: Gap.s),
                decoration: BoxDecoration(color: capsule, borderRadius: BorderRadius.circular(Radii.row)),
                child: Row(
                  children: [
                    Icon(Icons.record_voice_over_rounded, size: 20, color: accentInk),
                    const SizedBox(width: Gap.m),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text('Voice 2', style: Skin.ui(size: 15, weight: FontWeight.w600, color: ink)),
                          Text('English · 1.2×', style: Skin.ui(size: 13, weight: FontWeight.w400, color: p.inkSoftFor(b))),
                        ],
                      ),
                    ),
                    Text('Change', style: Skin.ui(size: 14, weight: FontWeight.w700, color: accentInk)),
                  ],
                ),
              ),
              const SizedBox(height: Gap.m),
              Container(
                padding: const EdgeInsets.symmetric(horizontal: Gap.l, vertical: Gap.s),
                decoration: BoxDecoration(color: p.accent, borderRadius: BorderRadius.circular(Radii.pill)),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Icon(Icons.play_arrow_rounded, size: 20, color: p.onAccent),
                    const SizedBox(width: Gap.xs),
                    Text('Play', style: Skin.ui(size: 15, weight: FontWeight.w700, color: p.onAccent)),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// What had to give for the colours to read, and the offer to take the
/// shades they were given.
class _Adjusted extends StatelessWidget {
  const _Adjusted({required this.made, required this.chosen, required this.onUse});

  final OwnPalette made;
  final OwnColours chosen;
  final VoidCallback onUse;

  @override
  Widget build(BuildContext context) {
    double tone(Color c) => Hct.fromInt(c.toARGB32()).tone;
    String way(Color from, Color to) => tone(to) < tone(from) ? 'darker' : 'lighter';
    final said = [
      if (made.page != null)
        'Text cannot be read on a page of that shade, so the nearest one it can is used.',
      if (made.ink != null) 'The text is ${way(chosen.ink!, made.ink!)} than you chose, so it reads on this page.',
      if (made.accent != null)
        'The accent is ${way(chosen.accent, made.accent!)} than you chose, so it shows on this page.',
    ];
    return Row(
      children: [
        Icon(Icons.contrast_rounded, size: 18, color: Skin.inkSoftOn(context)),
        const SizedBox(width: Gap.s),
        Expanded(
          child: Text(said.join(' '),
              style: Skin.ui(size: 13.5, weight: FontWeight.w400, color: Skin.inkSoftOn(context))),
        ),
        TextButton(onPressed: onUse, child: Text(said.length > 1 ? 'Use these shades' : 'Use this shade')),
      ],
    );
  }
}

/// The swatches for [part], the chosen one ringed. The text's row starts
/// with Automatic, text made to suit the page.
class _Swatches extends StatelessWidget {
  const _Swatches({required this.part, required this.selected, required this.onPick});

  final OwnPart part;
  final Color? selected;
  final ValueChanged<Color?> onPick;

  @override
  Widget build(BuildContext context) {
    final noun = part.label.toLowerCase();
    return Wrap(
      spacing: Gap.s,
      runSpacing: Gap.s,
      children: [
        if (part == OwnPart.ink) _swatch(context, 'Automatic text', null),
        for (final (name, c) in ownSwatches[part]!) _swatch(context, '$name $noun', c),
      ],
    );
  }

  Widget _swatch(BuildContext context, String label, Color? c) {
    final on = c == null ? selected == null : selected?.toARGB32() == c.toARGB32();
    final fill = c ?? Skin.raisedOn(context);
    return Semantics(
      button: true,
      selected: on,
      label: label,
      child: InkResponse(
        onTap: () => onPick(c),
        radius: 26,
        child: AnimatedContainer(
          duration: Motion.of(context, Motion.quick),
          width: 40,
          height: 40,
          decoration: BoxDecoration(
            color: fill,
            shape: BoxShape.circle,
            border: Border.all(
              color: on ? Skin.inkOn(context) : Skin.outlineOn(context),
              width: on ? 2.5 : 1,
            ),
          ),
          child: c == null
              ? Center(child: Text('A', style: Skin.ui(size: 15, weight: FontWeight.w700, color: Skin.inkSoftOn(context))))
              : null,
        ),
      ),
    );
  }
}

/// A colour picked on two bars: its hue round the colour wheel, and its
/// shade from black to white. Its colourfulness stays, but for a grey given
/// a hue, which takes [minChroma] to show it.
///
/// The hue and colourfulness are kept here, not read from the colour: at
/// either end of the Shade bar the colour is black or white, which has
/// neither, and brought back it came back grey.
class HueShadePicker extends StatefulWidget {
  const HueShadePicker({super.key, required this.colour, required this.onChanged, this.minChroma = 16});

  final Color colour;
  final ValueChanged<Color> onChanged;
  final double minChroma;

  @override
  State<HueShadePicker> createState() => _HueShadePickerState();
}

class _HueShadePickerState extends State<HueShadePicker> {
  late double _hue;
  late double _chroma;

  /// The colour last given out: given back, it is no new colour.
  Color? _sent;

  @override
  void initState() {
    super.initState();
    final hct = Hct.fromInt(widget.colour.toARGB32());
    _hue = hct.hue;
    _chroma = hct.chroma;
  }

  @override
  void didUpdateWidget(HueShadePicker old) {
    super.didUpdateWidget(old);
    // Another colour from outside (a swatch, another part): its own hue and
    // colourfulness, a grey's hue kept from before.
    if (widget.colour == old.colour || widget.colour == _sent) return;
    final hct = Hct.fromInt(widget.colour.toARGB32());
    if (hct.chroma >= 1) _hue = hct.hue;
    _chroma = hct.chroma;
  }

  Color _at(double hue, double chroma, double tone) => Color(Hct.from(hue, chroma, tone).toInt());

  void _send(Color c) {
    _sent = c;
    widget.onChanged(c);
  }

  @override
  Widget build(BuildContext context) {
    final tone = Hct.fromInt(widget.colour.toARGB32()).tone;
    // Pure black and white have no hue to show: the bar shows the hues at a
    // middle shade instead.
    final shownTone = tone.clamp(25.0, 85.0);
    final shown = _chroma < widget.minChroma ? widget.minChroma : _chroma;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _bar(
          context,
          label: 'Hue',
          value: _hue.clamp(0.0, 359.9),
          max: 359.9,
          colours: [for (var h = 0.0; h <= 360; h += 30) _at(h, shown, shownTone)],
          say: (v) => 'Hue, ${v.round()} degrees',
          onChanged: (h) {
            setState(() {
              _hue = h;
              _chroma = shown;
            });
            _send(_at(h, shown, tone));
          },
        ),
        const SizedBox(height: Gap.s),
        _bar(
          context,
          label: 'Shade',
          value: tone,
          max: 100,
          colours: [for (var t = 0.0; t <= 100; t += 10) _at(_hue, _chroma, t)],
          say: (v) => 'Shade, ${v.round()}% light',
          onChanged: (t) => _send(_at(_hue, _chroma, t)),
        ),
      ],
    );
  }

  Widget _bar(
    BuildContext context, {
    required String label,
    required double value,
    required double max,
    required List<Color> colours,
    required String Function(double) say,
    required ValueChanged<double> onChanged,
  }) =>
      Row(
        children: [
          SizedBox(
            width: 52,
            child: Text(label, style: Skin.ui(size: 14, weight: FontWeight.w500, color: Skin.inkSoftOn(context))),
          ),
          Expanded(
            child: SliderTheme(
              data: SliderTheme.of(context).copyWith(
                trackHeight: 14,
                trackShape: _GradientTrack(colours),
                thumbShape: _RingThumb(fill: widget.colour, ring: Skin.inkOn(context)),
                overlayColor: Skin.inkOn(context).withValues(alpha: 0.08),
              ),
              child: Slider(
                value: value.clamp(0, max).toDouble(),
                max: max,
                semanticFormatterCallback: say,
                onChanged: onChanged,
              ),
            ),
          ),
        ],
      );
}

/// A slider's track drawn as the colours along it.
class _GradientTrack extends SliderTrackShape with BaseSliderTrackShape {
  const _GradientTrack(this.colours);

  final List<Color> colours;

  @override
  void paint(
    PaintingContext context,
    Offset offset, {
    required RenderBox parentBox,
    required SliderThemeData sliderTheme,
    required Animation<double> enableAnimation,
    required Offset thumbCenter,
    Offset? secondaryOffset,
    bool isEnabled = false,
    bool isDiscrete = false,
    required TextDirection textDirection,
  }) {
    final rect = getPreferredRect(parentBox: parentBox, offset: offset, sliderTheme: sliderTheme);
    context.canvas.drawRRect(
      RRect.fromRectAndRadius(rect, Radius.circular(rect.height / 2)),
      Paint()..shader = LinearGradient(colors: colours).createShader(rect),
    );
  }
}

/// A slider's thumb: the colour picked, ringed so it shows on any track.
class _RingThumb extends SliderComponentShape {
  const _RingThumb({required this.fill, required this.ring});

  final Color fill;
  final Color ring;

  static const _radius = 12.0;

  @override
  Size getPreferredSize(bool isEnabled, bool isDiscrete) => const Size.fromRadius(_radius);

  @override
  void paint(
    PaintingContext context,
    Offset center, {
    required Animation<double> activationAnimation,
    required Animation<double> enableAnimation,
    required bool isDiscrete,
    required TextPainter labelPainter,
    required RenderBox parentBox,
    required SliderThemeData sliderTheme,
    required TextDirection textDirection,
    required double value,
    required double textScaleFactor,
    required Size sizeWithOverflow,
  }) {
    final canvas = context.canvas;
    canvas.drawCircle(center, _radius, Paint()..color = Colors.white);
    canvas.drawCircle(center, _radius - 2, Paint()..color = fill);
    canvas.drawCircle(
      center,
      _radius,
      Paint()
        ..color = ring
        ..style = PaintingStyle.stroke
        ..strokeWidth = 2,
    );
  }
}
