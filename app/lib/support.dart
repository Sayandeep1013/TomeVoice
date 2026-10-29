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

/// About's support section: the QR, a button that offers the phone's UPI
/// apps, and saving the QR to Pictures.
class SupportSection extends StatefulWidget {
  const SupportSection({super.key});

  @override
  State<SupportSection> createState() => _SupportSectionState();
}

class _SupportSectionState extends State<SupportSection> {
  bool _saving = false;

  Future<void> _pay() async {
    final opened = await _svc.payUpi(upiPayUrl, title: 'Pay with');
    if (!opened && mounted) {
      showSnack(context, 'No UPI app on this phone. Save the QR code and scan it from one that has.', long: true);
    }
  }

  Future<void> _save() async {
    if (_saving) return;
    setState(() => _saving = true);
    try {
      final data = await rootBundle.load(_qrAsset);
      final saved = await _svc.saveImage(data.buffer.asUint8List(), 'TomeVoice-UPI.png');
      if (saved && mounted) {
        showSnack(context, 'Saved to Pictures. Scan it from the gallery in any UPI app.', long: true);
      }
    } on Object {
      if (mounted) showSnack(context, 'Could not save the QR code.');
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  @override
  Widget build(BuildContext context) => Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          const SectionTitle('Support TomeVoice'),
          const SizedBox(height: Gap.s),
          Text(
            'TomeVoice is free and open source, with no ads and nothing to buy. If it reads '
            'you a good book, you can help keep it going with any amount, by UPI.',
            style: Skin.ui(size: 15, weight: FontWeight.w400, color: Skin.inkSoftOn(context)).copyWith(height: 1.5),
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
        ],
      );
}
