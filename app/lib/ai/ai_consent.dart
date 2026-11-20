import 'package:flutter/material.dart';

import '../theme.dart';
import 'ai_keys.dart';

/// What is sent to the AI, said before anything is: the reader agrees once
/// (kept with their keys), or nothing goes. True when they have agreed.
Future<bool> ensureAiConsent(BuildContext context, {AiRing? ring}) async {
  final r = ring ?? AiRing.instance;
  if (r.consented) return true;
  final yes = await showDialog<bool>(
        context: context,
        animationStyle: sheetMotion(context),
        builder: (ctx) => AlertDialog(
          title: const Text('Before the AI reads with you'),
          content: SingleChildScrollView(
            child: Text(
              aiConsentText,
              style: Skin.ui(size: 14.5, weight: FontWeight.w400, color: Skin.inkOn(ctx)).copyWith(height: 1.45),
            ),
          ),
          actions: [
            TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Not now')),
            FilledButton(onPressed: () => Navigator.pop(ctx, true), child: const Text('I agree')),
          ],
        ),
      ) ==
      true;
  if (yes) await r.consent();
  return yes;
}

/// The words of [ensureAiConsent].
const aiConsentText = 'With your own key, TomeVoice sends text straight from this phone to the AI provider you '
    'choose. There is no TomeVoice server, and nothing reaches the developer.\n\n'
    "To build a book's memory: the book's text, chapter by chapter.\n"
    'To answer a question: the passage you are at, the notes and parts of the book that bear on it, and journal '
    'entries that bear on it (you can turn that off).\n'
    'To tidy what you said into the journal: those words, when you tap Tidy.\n\n'
    'Books on a secret shelf, or kept away from the AI, are never sent. What the provider keeps, and whether it '
    'learns from it, is in its own terms. AI answers can be wrong: each can be reported from Talk.';
