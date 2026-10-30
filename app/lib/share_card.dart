import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart' show RenderRepaintBoundary;
import 'package:flutter/services.dart' show Clipboard, ClipboardData;

import 'book_tint.dart';
import 'marks.dart';
import 'speech_service.dart';
import 'theme.dart';
import 'ui.dart';

const _svc = SpeechService();

/// How the picture is cut: a post (4:5) or a story (9:16).
enum CardShape {
  post(4 / 5, 'Post'),
  story(9 / 16, 'Story');

  const CardShape(this.ratio, this.label);
  final double ratio;
  final String label;
}

/// A quote as a picture, in its book's colours: the words in the reading
/// face, the title in Bodoni, a small cover, and the TomeVoice mark.
class QuoteCard extends StatelessWidget {
  const QuoteCard({super.key, required this.mark, this.cover, this.author, this.shape = CardShape.post});

  final Mark mark;
  final String? cover;
  final String? author;
  final CardShape shape;

  @override
  Widget build(BuildContext context) {
    final accent = Skin.accentOf(context);
    final deep = Color.lerp(accent, Colors.black, 0.78)!;
    // A long quote is cut at a space, or where there is none (Chinese,
    // Japanese: cut at "no space found", it threw). Its length is the room it
    // takes, a wide character counting two letters: 420 of them were twice
    // the card.
    final cut = _cutAt(mark.text, 420);
    final words = cut < mark.text.length ? '${mark.text.substring(0, cut)}…' : mark.text;
    final room = _room(words);
    final size = room < 120 ? 26.0 : (room < 240 ? 21.0 : 17.0);
    return AspectRatio(
      aspectRatio: shape.ratio,
      child: DecoratedBox(
        decoration: BoxDecoration(
          gradient: RadialGradient(
            center: const Alignment(-0.6, -1),
            radius: 1.6,
            colors: [Color.lerp(accent, Colors.black, 0.55)!, deep, Colors.black],
            stops: const [0, 0.55, 1],
          ),
        ),
        child: Padding(
          padding: const EdgeInsets.fromLTRB(26, 26, 26, 22),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  const Spacer(),
                  Text('TOMEVOICE', style: Skin.meta(context, color: Colors.white.withValues(alpha: 0.55), size: 9)),
                ],
              ),
              const Spacer(),
              Text('“', style: Skin.title(context, size: 56, color: Skin.accentSoftOf(context)).copyWith(height: 0.6)),
              const SizedBox(height: 6),
              Text(
                words,
                style: TextStyle(
                  fontFamily: 'Newsreader',
                  fontStyle: FontStyle.italic,
                  fontSize: size,
                  height: 1.36,
                  color: Colors.white,
                ),
              ),
              const Spacer(),
              Container(height: 1, color: Colors.white.withValues(alpha: 0.14)),
              const SizedBox(height: 14),
              Row(
                children: [
                  if (cover != null) ...[
                    ClipRRect(
                      borderRadius: BorderRadius.circular(4),
                      child: Image.file(File(cover!), width: 34, height: 50, fit: BoxFit.cover, cacheWidth: 120),
                    ),
                    const SizedBox(width: 12),
                  ],
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(mark.bookTitle,
                            maxLines: 2,
                            overflow: TextOverflow.ellipsis,
                            style: Skin.title(context, size: 16, color: Colors.white)),
                        const SizedBox(height: 3),
                        Text(
                          [if (author != null && author!.isNotEmpty) author!, if (mark.chapter != null) mark.chapter!]
                              .join(' · ')
                              .toUpperCase(),
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: Skin.meta(context, size: 9.5, color: Colors.white.withValues(alpha: 0.6)),
                        ),
                      ],
                    ),
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// A character drawn about twice a Latin letter's width: Chinese, Japanese
/// and Korean, and the full-width forms.
bool _wide(int r) =>
    (r >= 0x1100 && r <= 0x115F) ||
    (r >= 0x2E80 && r <= 0xA4CF) ||
    (r >= 0xAC00 && r <= 0xD7A3) ||
    (r >= 0xF900 && r <= 0xFAFF) ||
    (r >= 0xFE30 && r <= 0xFE4F) ||
    (r >= 0xFF00 && r <= 0xFF60) ||
    (r >= 0xFFE0 && r <= 0xFFE6) ||
    (r >= 0x20000 && r <= 0x3FFFD);

/// The room [text] takes, in Latin letters.
int _room(String text) => text.runes.fold(0, (n, r) => n + (_wide(r) ? 2 : 1));

/// Where to cut [text] to fit [room]: at the last space before that point,
/// or at it where there is none; its length when it all fits.
int _cutAt(String text, int room) {
  var used = 0;
  var i = 0;
  for (final r in text.runes) {
    final w = _wide(r) ? 2 : 1;
    if (used + w > room) break;
    used += w;
    i += r > 0xFFFF ? 2 : 1;
  }
  if (i >= text.length) return text.length;
  final space = text.lastIndexOf(' ', i);
  return space > 0 ? space : i;
}

/// Preview [mark] as a picture, then share it (or copy its words).
Future<void> showQuoteShare(BuildContext context, Mark mark, {String? cover, String? author}) =>
    showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      useSafeArea: true,
      builder: (_) => carryTint(context, _ShareSheet(mark: mark, cover: cover, author: author)),
    );

class _ShareSheet extends StatefulWidget {
  const _ShareSheet({required this.mark, this.cover, this.author});

  final Mark mark;
  final String? cover;
  final String? author;

  @override
  State<_ShareSheet> createState() => _ShareSheetState();
}

class _ShareSheetState extends State<_ShareSheet> {
  final _card = GlobalKey();

  /// The card's layout width; shared pictures are 1080 pixels wide.
  static const _cardWidth = 360.0;
  CardShape _shape = CardShape.post;
  bool _busy = false;

  Future<void> _share() async {
    final boundary = _card.currentContext?.findRenderObject();
    if (boundary is! RenderRepaintBoundary || _busy) return;
    setState(() => _busy = true);
    try {
      // 1080 pixels wide, whatever the preview's size on screen.
      final image = await boundary.toImage(pixelRatio: 1080 / _cardWidth);
      final png = await image.toByteData(format: ui.ImageByteFormat.png);
      image.dispose();
      final dir = await _svc.shareDir();
      if (png == null || dir == null) throw const FileSystemException('No picture');
      final file = File('$dir/quote-${DateTime.now().millisecondsSinceEpoch}.png');
      await file.writeAsBytes(png.buffer.asUint8List());
      await _svc.shareImage(file.path, text: '“${widget.mark.text}” — ${widget.mark.bookTitle}');
    } on Object catch (e) {
      debugPrint('Sharing a quote failed: $e');
      if (mounted) showSnack(context, 'The picture could not be shared. Try again, or copy the words.');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final card = QuoteCard(mark: widget.mark, cover: widget.cover, author: widget.author, shape: _shape);
    return SafeArea(
      child: SingleChildScrollView(
        padding: const EdgeInsets.fromLTRB(Gap.xl, 0, Gap.xl, Gap.l),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            const SheetHeader('Share this line'),
            ChoiceRow<CardShape>(
              options: [for (final s in CardShape.values) (s, s.label)],
              value: _shape,
              onChanged: (s) => setState(() => _shape = s),
            ),
            const SizedBox(height: Gap.l),
            // Always laid out at the same size, so a long quote fits the
            // same way on every phone; the preview is that, scaled to fit.
            Center(
              child: ConstrainedBox(
                constraints: BoxConstraints(maxHeight: MediaQuery.sizeOf(context).height * 0.55, maxWidth: 360),
                child: FittedBox(
                  child: ClipRRect(
                    borderRadius: BorderRadius.circular(Radii.card / 2),
                    child: RepaintBoundary(
                      key: _card,
                      child: SizedBox(width: _cardWidth, height: _cardWidth / _shape.ratio, child: card),
                    ),
                  ),
                ),
              ),
            ),
            const SizedBox(height: Gap.l),
            Row(
              children: [
                Expanded(
                  child: OutlinedButton.icon(
                    onPressed: () async {
                      await Clipboard.setData(ClipboardData(text: '“${widget.mark.text}” — ${widget.mark.bookTitle}'));
                      if (context.mounted) showSnack(context, 'Copied.');
                    },
                    icon: const Icon(Icons.copy_rounded, size: 18),
                    label: const Text('Copy words'),
                  ),
                ),
                const SizedBox(width: Gap.m),
                Expanded(
                  child: FilledButton.icon(
                    onPressed: _busy ? null : _share,
                    icon: const Icon(Icons.ios_share_rounded, size: 18),
                    label: const Text('Share picture'),
                  ),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}
