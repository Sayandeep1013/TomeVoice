"""A made-up book site for testing book-file sources in the TEST app only.

"Pagebound Library": a sign-in form that sets a session cookie, search and a
popular list (JSON), a book page with its files, downloads that need the
session (401 without it), a daily limit per session (429 after 3 downloads),
and /expire to end every session (to see the app ask to sign in again).
Public-domain books only: Pride and Prejudice (the app's own starter EPUB),
a small EPUB made here, and a small PDF made here.

It also serves the test plugin (/pagebound.js) and its source list
(/plugins.json), in LNReader's format.

Run:  python -I tools/phone/test_book_site.py [port]   (default 8099)
Then: adb reverse tcp:8099 tcp:8099
In the TEST app: Browse > Sources > Add a source list >
http://127.0.0.1:8099/plugins.json, install Pagebound Library.
Sign in: reader / pages.
"""
import io
import json
import os
import secrets
import sys
import time
import zipfile
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from urllib.parse import parse_qs, urlparse

PORT = int(sys.argv[1]) if len(sys.argv) > 1 else 8099
SITE = f'http://127.0.0.1:{PORT}/'
HERE = os.path.dirname(os.path.abspath(__file__))
STARTER = os.path.join(HERE, '..', '..', 'app', 'assets', 'starter', 'pride-and-prejudice.epub')
USER, PASSWORD = 'reader', 'pages'
DAILY = 3
SESSIONS = {}  # token -> {'until': t, 'downloads': n}


def small_epub(title, author, chapters):
    """A minimal valid EPUB 3 of [chapters] (title, text)."""
    buf = io.BytesIO()
    with zipfile.ZipFile(buf, 'w') as z:
        z.writestr(zipfile.ZipInfo('mimetype'), 'application/epub+zip', compress_type=zipfile.ZIP_STORED)
        z.writestr('META-INF/container.xml',
                   '<?xml version="1.0"?><container version="1.0" xmlns="urn:oasis:names:tc:opendocument:xmlns:container">'
                   '<rootfiles><rootfile full-path="OEBPS/content.opf" media-type="application/oebps-package+xml"/>'
                   '</rootfiles></container>')
        items, spine, nav = [], [], []
        for i, (t, text) in enumerate(chapters, 1):
            name = f'ch{i}.xhtml'
            body = ''.join(f'<p>{p}</p>' for p in text.split('\n'))
            z.writestr(f'OEBPS/{name}',
                       f'<?xml version="1.0" encoding="utf-8"?><html xmlns="http://www.w3.org/1999/xhtml"><head>'
                       f'<title>{t}</title></head><body><h1>{t}</h1>{body}</body></html>')
            items.append(f'<item id="c{i}" href="{name}" media-type="application/xhtml+xml"/>')
            spine.append(f'<itemref idref="c{i}"/>')
            nav.append(f'<li><a href="{name}">{t}</a></li>')
        z.writestr('OEBPS/nav.xhtml',
                   '<?xml version="1.0" encoding="utf-8"?><html xmlns="http://www.w3.org/1999/xhtml" '
                   'xmlns:epub="http://www.idpf.org/2007/ops"><head><title>Contents</title></head><body>'
                   f'<nav epub:type="toc"><ol>{"".join(nav)}</ol></nav></body></html>')
        z.writestr('OEBPS/content.opf',
                   '<?xml version="1.0" encoding="utf-8"?><package xmlns="http://www.idpf.org/2007/opf" version="3.0" '
                   'unique-identifier="id"><metadata xmlns:dc="http://purl.org/dc/elements/1.1/">'
                   f'<dc:identifier id="id">pagebound-{title.lower().replace(" ", "-")}</dc:identifier>'
                   f'<dc:title>{title}</dc:title><dc:creator>{author}</dc:creator><dc:language>en</dc:language>'
                   '<meta property="dcterms:modified">2026-11-22T00:00:00Z</meta></metadata><manifest>'
                   '<item id="nav" href="nav.xhtml" media-type="application/xhtml+xml" properties="nav"/>'
                   f'{"".join(items)}</manifest><spine>{"".join(spine)}</spine></package>')
    return buf.getvalue()


def small_pdf(title, lines):
    """A one-page PDF with [lines] of text."""
    text = 'BT /F1 14 Tf 72 740 Td 18 TL ' + ' '.join(
        f'({l.replace("(", "").replace(")", "")}) Tj T*' for l in [title, ''] + lines) + ' ET'
    objs = [
        '<< /Type /Catalog /Pages 2 0 R >>',
        '<< /Type /Pages /Kids [3 0 R] /Count 1 >>',
        '<< /Type /Page /Parent 2 0 R /MediaBox [0 0 612 792] /Contents 4 0 R '
        '/Resources << /Font << /F1 5 0 R >> >> >>',
        f'<< /Length {len(text)} >>\nstream\n{text}\nendstream',
        '<< /Type /Font /Subtype /Type1 /BaseFont /Times-Roman >>',
    ]
    out, offsets = b'%PDF-1.4\n', []
    for i, o in enumerate(objs, 1):
        offsets.append(len(out))
        out += f'{i} 0 obj\n{o}\nendobj\n'.encode()
    xref = len(out)
    out += f'xref\n0 {len(objs) + 1}\n0000000000 65535 f \n'.encode()
    for off in offsets:
        out += f'{off:010d} 00000 n \n'.encode()
    out += f'trailer\n<< /Size {len(objs) + 1} /Root 1 0 R >>\nstartxref\n{xref}\n%%EOF\n'.encode()
    return out


TALE = [
    ('The Lighthouse', 'The keeper climbed the stair at dusk.\nThe lamp turned, and the sea answered.'),
    ('The Storm', 'Rain came sideways off the water.\nShe counted the ships that did not come home.'),
    ('The Morning', 'At dawn the harbour was full of gulls.\nOne boat came back, its sail torn, its crew singing.'),
]
with open(STARTER, 'rb') as f:
    PRIDE = f.read()
FILES = {
    'pride.epub': PRIDE,
    'keeper.epub': small_epub('The Keeper of the Light', 'Pagebound Press', TALE),
    'keeper.pdf': small_pdf('The Keeper of the Light', ['The keeper climbed the stair at dusk.', 'The lamp turned.']),
}
BOOKS = [
    {'id': '1', 'name': 'Pride and Prejudice', 'author': 'Jane Austen', 'year': '1813', 'language': 'English',
     'summary': 'A public-domain classic: the Bennet sisters, Mr Darcy, and first impressions.',
     'files': [{'format': 'epub', 'file': 'pride.epub'}]},
    {'id': '2', 'name': 'The Keeper of the Light', 'author': 'Pagebound Press', 'year': '2026', 'language': 'English',
     'summary': 'A short made-up tale for testing: a lighthouse keeper through one storm.',
     'files': [{'format': 'epub', 'file': 'keeper.epub'}, {'format': 'pdf', 'file': 'keeper.pdf'}]},
]

PLUGIN = r'''
var fetchApi = require('@libs/fetch').fetchApi;
var SITE = '%SITE%';
function item(b) { return { name: b.name, path: 'book/' + b.id, cover: null }; }
exports.default = {
  id: 'pagebound',
  name: 'Pagebound Library',
  site: SITE,
  version: '1.0.0',
  filters: {},
  popularNovels: function (page) {
    return fetchApi(SITE + 'api/popular?page=' + page).then(function (r) { return r.json(); })
      .then(function (j) { return j.map(item); });
  },
  searchNovels: function (q, page) {
    return fetchApi(SITE + 'api/search?q=' + encodeURIComponent(q) + '&page=' + page)
      .then(function (r) { return r.json(); }).then(function (j) { return j.map(item); });
  },
  parseBook: function (path) {
    return fetchApi(SITE + 'api/' + path).then(function (r) { return r.json(); }).then(function (b) {
      return {
        name: b.name, author: b.author, summary: b.summary, year: b.year, language: b.language,
        files: b.files.map(function (f) {
          return { format: f.format, url: SITE + 'dl/' + f.file, size: f.size,
                   label: f.format.toUpperCase() + ' · ' + Math.max(1, Math.round(f.size / 1024)) + ' KB' };
        }),
      };
    });
  },
  parseNovel: function (path) { return { path: path, name: '', chapters: [] }; },
  parseChapter: function () { return ''; },
};
'''.replace('%SITE%', SITE)


class Handler(BaseHTTPRequestHandler):
    def _session(self):
        for part in (self.headers.get('Cookie') or '').split(';'):
            k, _, v = part.strip().partition('=')
            if k == 'pb_session' and v in SESSIONS and SESSIONS[v]['until'] > time.time():
                return v
        return None

    def _send(self, code, body, ctype='application/json', extra=None):
        data = body if isinstance(body, bytes) else (json.dumps(body) if ctype == 'application/json' else body).encode()
        self.send_response(code)
        self.send_header('Content-Type', ctype)
        self.send_header('Content-Length', str(len(data)))
        for k, v in (extra or {}).items():
            self.send_header(k, v)
        self.end_headers()
        self.wfile.write(data)

    def log_message(self, fmt, *args):
        sys.stdout.write('%s %s\n' % (time.strftime('%H:%M:%S'), fmt % args))

    def do_GET(self):
        u = urlparse(self.path)
        q = parse_qs(u.query)
        s = self._session()
        if u.path == '/':
            if s:
                body = (f'<html><body style="font-family:sans-serif;padding:2em"><h1>Pagebound Library</h1>'
                        f'<p>Signed in as {USER}. Downloads left today: {DAILY - SESSIONS[s]["downloads"]}.</p>'
                        f'<p><a href="/logout">Sign out</a></p></body></html>')
            else:
                body = ('<html><body style="font-family:sans-serif;padding:2em"><h1>Pagebound Library</h1>'
                        '<p>Sign in to download books.</p><form method="post" action="/login">'
                        '<p><input name="user" placeholder="User name"></p>'
                        '<p><input name="password" type="password" placeholder="Password"></p>'
                        '<p><button type="submit">Sign in</button></p></form></body></html>')
            return self._send(200, body, 'text/html; charset=utf-8')
        if u.path == '/logout':
            if s:
                SESSIONS.pop(s, None)
            return self._send(302, b'', 'text/plain', {'Location': '/', 'Set-Cookie': 'pb_session=; Max-Age=0; Path=/'})
        if u.path == '/expire':
            SESSIONS.clear()
            return self._send(200, {'expired': True})
        if u.path == '/plugins.json':
            code = PLUGIN.encode()
            return self._send(200, [{'id': 'pagebound', 'name': 'Pagebound Library', 'site': SITE, 'lang': 'English',
                                     'version': '1.0.0', 'url': SITE + 'pagebound.js', 'iconUrl': None}])
        if u.path == '/pagebound.js':
            return self._send(200, PLUGIN, 'application/javascript')
        if u.path in ('/api/popular', '/api/search'):
            term = (q.get('q') or [''])[0].lower()
            page = int((q.get('page') or ['1'])[0])
            found = [b for b in BOOKS if term in (b['name'] + ' ' + b['author']).lower()] if term else BOOKS
            return self._send(200, [{'id': b['id'], 'name': b['name']} for b in found] if page == 1 else [])
        if u.path.startswith('/api/book/'):
            b = next((b for b in BOOKS if b['id'] == u.path.rsplit('/', 1)[1]), None)
            if not b:
                return self._send(404, {'error': 'No such book'})
            files = [dict(f, size=len(FILES[f['file']])) for f in b['files']]
            return self._send(200, dict(b, files=files))
        if u.path.startswith('/dl/'):
            name = u.path[4:]
            if name not in FILES:
                return self._send(404, {'error': 'No such file'})
            if not s:
                return self._send(401, {'error': 'Sign in to download'})
            if SESSIONS[s]['downloads'] >= DAILY:
                return self._send(429, {'error': 'Daily download limit reached'}, extra={'Retry-After': '3600'})
            SESSIONS[s]['downloads'] += 1
            ctype = 'application/pdf' if name.endswith('.pdf') else 'application/epub+zip'
            return self._send(200, FILES[name], ctype, {'Content-Disposition': f'attachment; filename="{name}"'})
        return self._send(404, {'error': 'Not found'})

    def do_POST(self):
        u = urlparse(self.path)
        n = int(self.headers.get('Content-Length') or 0)
        form = parse_qs(self.rfile.read(n).decode())
        if u.path == '/login':
            if (form.get('user') or [''])[0] == USER and (form.get('password') or [''])[0] == PASSWORD:
                token = secrets.token_hex(16)
                SESSIONS[token] = {'until': time.time() + 3600, 'downloads': 0}
                return self._send(302, b'', 'text/plain',
                                  {'Location': '/', 'Set-Cookie': f'pb_session={token}; Path=/; Max-Age=3600; HttpOnly'})
            return self._send(200, '<html><body><p>Wrong user name or password.</p><a href="/">Back</a></body></html>',
                              'text/html; charset=utf-8')
        return self._send(404, {'error': 'Not found'})


if __name__ == '__main__':
    print(f'Pagebound Library on {SITE} (sign in: {USER} / {PASSWORD})')
    ThreadingHTTPServer(('127.0.0.1', PORT), Handler).serve_forever()
