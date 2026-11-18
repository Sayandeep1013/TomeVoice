import 'package:flutter/material.dart';

import '../../journal.dart';
import '../../notebook.dart' show savedWhen;
import '../../theme.dart';
import '../../ui.dart';
import 'talk_engine.dart';

/// A talk kept in the journal, to read again: the reader's questions and
/// the answers, the chapters they cited named.
class TalkTranscript extends StatelessWidget {
  const TalkTranscript({super.key, required this.entry});

  final JournalEntry entry;

  /// An answer's [S3] marks taken out: the places they named are not kept.
  static String plain(String text) => text.replaceAll(citeMarks, '').replaceAllMapped(RegExp(r' +([.,;:!?])'), (m) => m.group(1)!);

  @override
  Widget build(BuildContext context) => Scaffold(
        body: DecoratedBox(
          decoration: BoxDecoration(gradient: Skin.ground(context)),
          child: SafeArea(
            bottom: false,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                ScreenTopBar(title: 'A talk', onBack: () => Navigator.of(context).maybePop()),
                Padding(
                  padding: const EdgeInsets.fromLTRB(Gap.page, 0, Gap.page, Gap.m),
                  child: Text('${entry.bookTitle} · ${entry.stamp.label} · ${savedWhen(entry.created)}',
                      style: Skin.meta(context)),
                ),
                Expanded(
                  child: ListView(
                    padding: EdgeInsets.fromLTRB(Gap.page, 0, Gap.page, Gap.xxl + MediaQuery.viewPaddingOf(context).bottom),
                    children: [
                      for (final l in entry.talk)
                        l.mine
                            ? Align(
                                alignment: Alignment.centerRight,
                                child: Container(
                                  margin: const EdgeInsets.only(top: Gap.m, left: 48),
                                  padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
                                  decoration: BoxDecoration(
                                    color: Skin.capsuleOn(context),
                                    borderRadius: BorderRadius.circular(18),
                                  ),
                                  child: Text(l.text,
                                      style: Skin.ui(size: 15, weight: FontWeight.w500, color: Skin.inkOn(context))),
                                ),
                              )
                            : Padding(
                                padding: const EdgeInsets.only(top: Gap.m, right: 24),
                                child: Text(
                                  plain(l.text),
                                  style: Skin.ui(size: 15.5, weight: FontWeight.w400, color: Skin.inkOn(context))
                                      .copyWith(height: 1.45),
                                ),
                              ),
                    ],
                  ),
                ),
              ],
            ),
          ),
        ),
      );
}
