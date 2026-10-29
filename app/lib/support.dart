import 'package:flutter/material.dart';
import 'package:flutter/services.dart' show rootBundle;

import 'speech_service.dart';
import 'theme.dart';
import 'ui.dart';

const _svc = SpeechService();

/// The link a UPI app opens at: the payee (the ID the QR in assets/support
/// pays) and a note, in rupees, the amount left to the reader. The ID is not
/// shown: the QR is what readers see.
const upiPayUrl = 'upi://pay?pa=9330562712-3@ibl&pn=SAYANDEEP%20MONDAL&cu=INR&tn=Support%20TomeVoice';

const _qrAsset = 'assets/support/upi_qr.png';

/// About > Support TomeVoice: the QR, shown only when asked for, with a
/// button that offers the phone's UPI apps and one that saves the QR.
Future<void> showSupport(BuildContext context) => showModalBottomSheet<void>(
      context: context,
      useSafeArea: true,
      isScrollControlled: true,
      builder: (_) => const SafeArea(child: _SupportSheet()),
    );

class _SupportSheet extends StatefulWidget {
  const _SupportSheet();

  @override
  State<_SupportSheet> createState() => _SupportSheetState();
}

class _SupportSheetState extends State<_SupportSheet> {
  bool _saving = false;

  /// What became of Pay or Save, said in the sheet: a snack bar would sit
  /// under it.
  String? _note;

  Future<void> _pay() async {
    final opened = await _svc.payUpi(upiPayUrl, title: 'Pay with');
    if (!opened && mounted) {
      setState(() => _note = 'No UPI app on this phone. Save the QR and scan it from one that has.');
    }
  }

  Future<void> _save() async {
    if (_saving) return;
    setState(() {
      _saving = true;
      _note = null;
    });
    try {
      final data = await rootBundle.load(_qrAsset);
      final saved = await _svc.saveImage(data.buffer.asUint8List(), 'TomeVoice-UPI.png');
      if (saved && mounted) setState(() => _note = 'Saved to Pictures. Scan it from the gallery in any UPI app.');
    } on Object {
      if (mounted) setState(() => _note = 'Could not save the QR.');
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  @override
  Widget build(BuildContext context) => SingleChildScrollView(
        padding: const EdgeInsets.only(bottom: Gap.l),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            const SheetHeader('Support TomeVoice', subtitle: 'Any amount, by UPI'),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: Gap.xl),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Text(
                    'TomeVoice is free and open source, with no ads and nothing to buy. If it reads '
                    'you a good book, you can help keep it going.',
                    style: Skin.ui(size: 15, weight: FontWeight.w400, color: Skin.inkSoftOn(context))
                        .copyWith(height: 1.5),
                  ),
                  const SizedBox(height: Gap.l),
                  Center(
                    child: Semantics(
                      image: true,
                      label: 'UPI QR code',
                      child: ClipRRect(
                        borderRadius: BorderRadius.circular(Radii.row),
                        child: Image.asset(_qrAsset, width: 240, filterQuality: FilterQuality.medium),
                      ),
                    ),
                  ),
                  const SizedBox(height: Gap.l),
                  Row(
                    children: [
                      Expanded(
                        flex: 3,
                        child: FilledButton.icon(
                          onPressed: _pay,
                          icon: const Icon(Icons.currency_rupee_rounded, size: 20),
                          label: const Text('Pay with UPI'),
                        ),
                      ),
                      const SizedBox(width: Gap.m),
                      Expanded(
                        flex: 2,
                        child: OutlinedButton.icon(
                          onPressed: _saving ? null : _save,
                          icon: const Icon(Icons.download_rounded, size: 20),
                          label: const Text('Save QR'),
                        ),
                      ),
                    ],
                  ),
                  if (_note != null) ...[
                    const SizedBox(height: Gap.m),
                    Text(
                      _note!,
                      textAlign: TextAlign.center,
                      style: Skin.ui(size: 13.5, weight: FontWeight.w400, color: Skin.inkFaintOn(context)),
                    ),
                  ],
                ],
              ),
            ),
          ],
        ),
      );
}
