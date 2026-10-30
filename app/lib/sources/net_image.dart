import 'dart:ui' as ui;

import 'package:flutter/foundation.dart';
import 'package:flutter/painting.dart';

import 'net.dart';

/// A picture a source or a source list names (a cover, an icon), fetched
/// through [Net] like the source's pages: only from the open internet, with
/// the source's own cookies ([partition]) and its site as referrer. A
/// plugin's cover address cannot make the app ask the phone's own network.
@immutable
class NetImage extends ImageProvider<NetImage> {
  const NetImage(this.url, {this.referer, this.partition = ''});

  final String url;
  final String? referer;
  final String partition;

  @override
  Future<NetImage> obtainKey(ImageConfiguration configuration) => SynchronousFuture<NetImage>(this);

  @override
  ImageStreamCompleter loadImage(NetImage key, ImageDecoderCallback decode) =>
      MultiFrameImageStreamCompleter(codec: _load(key, decode), scale: 1, debugLabel: key.url);

  static Future<ui.Codec> _load(NetImage key, ImageDecoderCallback decode) async {
    final r = await Net.instance.request(
      key.url,
      headers: {
        'Accept': 'image/avif,image/webp,image/*,*/*;q=0.8',
        if (key.referer != null) 'Referer': key.referer!,
      },
      partition: key.partition,
      maxBytes: 8 << 20,
    );
    if (!r.ok || r.bytes.isEmpty) throw NetworkImageLoadException(statusCode: r.status, uri: Uri.parse(key.url));
    return decode(await ui.ImmutableBuffer.fromUint8List(r.bytes));
  }

  @override
  bool operator ==(Object other) =>
      other is NetImage && other.url == url && other.partition == partition && other.referer == referer;

  @override
  int get hashCode => Object.hash(url, partition, referer);
}
