// QuickJS has no atob/btoa; some entities versions need atob at load time,
// and a few plugins call them. Evaluated before anything else in the bundle.
if (typeof globalThis.atob !== 'function') {
  const A = 'ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/';
  globalThis.atob = function (s) {
    s = String(s).replace(/[\t\n\f\r =]/g, '');
    let out = '', buf = 0, bits = 0;
    for (let i = 0; i < s.length; i++) {
      const v = A.indexOf(s.charAt(i));
      if (v < 0) throw new Error('atob: invalid character');
      buf = (buf << 6) | v; bits += 6;
      if (bits >= 8) { bits -= 8; out += String.fromCharCode((buf >> bits) & 255); }
    }
    return out;
  };
  globalThis.btoa = function (s) {
    s = String(s); let out = '';
    for (let i = 0; i < s.length; i += 3) {
      const a = s.charCodeAt(i), b = s.charCodeAt(i + 1), c = s.charCodeAt(i + 2);
      const n = (a << 16) | ((b || 0) << 8) | (c || 0);
      out += A[(n >> 18) & 63] + A[(n >> 12) & 63] + (isNaN(b) ? '=' : A[(n >> 6) & 63]) + (isNaN(c) ? '=' : A[n & 63]);
    }
    return out;
  };
}
