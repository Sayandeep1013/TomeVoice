// QuickJS has no TextEncoder or TextDecoder, and @noble/ciphers' utils use
// them for UTF-8. UTF-8 only; evaluated before the libraries in extra.js.
if (typeof globalThis.TextEncoder !== 'function') {
  globalThis.TextEncoder = class TextEncoder {
    get encoding() { return 'utf-8'; }
    encode(input = '') {
      const s = String(input);
      const out = [];
      for (let i = 0; i < s.length; i++) {
        let c = s.charCodeAt(i);
        if (c >= 0xd800 && c < 0xdc00 && i + 1 < s.length) {
          const d = s.charCodeAt(i + 1);
          if (d >= 0xdc00 && d < 0xe000) {
            c = 0x10000 + ((c - 0xd800) << 10) + (d - 0xdc00);
            i++;
          }
        }
        if (c >= 0xd800 && c < 0xe000) c = 0xfffd;
        if (c < 0x80) out.push(c);
        else if (c < 0x800) out.push(0xc0 | (c >> 6), 0x80 | (c & 63));
        else if (c < 0x10000) out.push(0xe0 | (c >> 12), 0x80 | ((c >> 6) & 63), 0x80 | (c & 63));
        else out.push(0xf0 | (c >> 18), 0x80 | ((c >> 12) & 63), 0x80 | ((c >> 6) & 63), 0x80 | (c & 63));
      }
      return new Uint8Array(out);
    }
  };
}
if (typeof globalThis.TextDecoder !== 'function') {
  globalThis.TextDecoder = class TextDecoder {
    get encoding() { return 'utf-8'; }
    decode(input) {
      if (input == null) return '';
      const b = input instanceof Uint8Array ? input : new Uint8Array(input.buffer || input, input.byteOffset || 0, input.byteLength);
      let s = '';
      for (let i = 0; i < b.length; ) {
        const x = b[i];
        let c = 0xfffd;
        let n = 1;
        if (x < 0x80) c = x;
        else if (x >= 0xc2 && x < 0xe0 && i + 1 < b.length) { c = ((x & 31) << 6) | (b[i + 1] & 63); n = 2; }
        else if (x >= 0xe0 && x < 0xf0 && i + 2 < b.length) { c = ((x & 15) << 12) | ((b[i + 1] & 63) << 6) | (b[i + 2] & 63); n = 3; }
        else if (x >= 0xf0 && x < 0xf5 && i + 3 < b.length) {
          c = ((x & 7) << 18) | ((b[i + 1] & 63) << 12) | ((b[i + 2] & 63) << 6) | (b[i + 3] & 63);
          n = 4;
        }
        s += String.fromCodePoint(c);
        i += n;
      }
      return s;
    }
  };
}
