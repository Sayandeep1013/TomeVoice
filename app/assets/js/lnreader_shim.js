// TomeVoice host for LNReader source plugins. Evaluated after
// lnreader_libs.js. Gives plugins the same `require` the LNReader app does
// (src/plugins/pluginManager.ts, MIT), with fetch and storage bridged to
// Dart through sendMessage. Each plugin runs in a context of its own, and
// Dart knows which one is asking from that, not from anything said here.
(function () {
  'use strict';
  var g = globalThis;
  var L = g.__tvLibs;
  // The bridge as it is now, before any plugin code runs: a plugin that
  // replaces the global only changes it for itself.
  var send = g.sendMessage;

  // flutter_qjs provides setTimeout but not clearTimeout.
  if (typeof g.clearTimeout !== 'function') g.clearTimeout = function () {};

  var lc = function (k) { return String(k).toLowerCase(); };

  function Headers(init) {
    this._m = {};
    if (init) {
      var src = init instanceof Headers ? init._m : init;
      for (var k in src) if (src[k] != null) this._m[lc(k)] = String(src[k]);
    }
  }
  Headers.prototype.get = function (k) { var v = this._m[lc(k)]; return v === undefined ? null : v; };
  Headers.prototype.has = function (k) { return lc(k) in this._m; };
  Headers.prototype.set = function (k, v) { this._m[lc(k)] = String(v); };
  Headers.prototype.append = function (k, v) {
    var key = lc(k);
    this._m[key] = key in this._m ? this._m[key] + ', ' + v : String(v);
  };
  Headers.prototype['delete'] = function (k) { delete this._m[lc(k)]; };
  Headers.prototype.forEach = function (cb) { for (var k in this._m) cb(this._m[k], k, this); };
  Headers.prototype.entries = function () { return Object.entries(this._m)[Symbol.iterator](); };
  Headers.prototype[Symbol.iterator] = function () { return this.entries(); };

  function FormData() { this._p = []; }
  FormData.prototype.append = function (k, v) { this._p.push([String(k), String(v)]); };
  FormData.prototype.set = function (k, v) {
    this._p = this._p.filter(function (p) { return p[0] !== String(k); });
    this.append(k, v);
  };
  FormData.prototype.get = function (k) {
    for (var i = 0; i < this._p.length; i++) if (this._p[i][0] === String(k)) return this._p[i][1];
    return null;
  };

  function Response(r) {
    this.status = r.status;
    this.statusText = r.statusText || '';
    this.ok = r.status >= 200 && r.status < 300;
    this.url = r.url;
    this.redirected = !!r.redirected;
    this.headers = new Headers(r.headers);
    this._body = r.body == null ? '' : r.body;
  }
  Response.prototype.text = function () { return Promise.resolve(this._body); };
  Response.prototype.json = function () {
    var body = this._body;
    return Promise.resolve().then(function () { return JSON.parse(body); });
  };

  function normalize(init) {
    init = init || {};
    var h = {};
    var src = init.headers instanceof Headers ? init.headers._m : (init.headers || {});
    for (var k in src) if (src[k] != null) h[k] = String(src[k]);
    var has = function (name) { return Object.keys(h).some(function (x) { return lc(x) === name; }); };
    if (init.referrer && !has('referer')) h['Referer'] = String(init.referrer);
    var body = init.body;
    if (body instanceof FormData) {
      body = body._p.map(function (p) {
        return encodeURIComponent(p[0]) + '=' + encodeURIComponent(p[1]);
      }).join('&');
      if (!has('content-type')) h['Content-Type'] = 'application/x-www-form-urlencoded;charset=UTF-8';
    } else if (typeof URLSearchParams !== 'undefined' && body instanceof URLSearchParams) {
      body = body.toString();
      if (!has('content-type')) h['Content-Type'] = 'application/x-www-form-urlencoded;charset=UTF-8';
    } else if (body != null && typeof body !== 'string') {
      body = String(body);
    }
    return { method: String(init.method || 'GET').toUpperCase(), headers: h, body: body == null ? null : body };
  }

  function fetchApi(url, init) {
    return send('tv_fetch', JSON.stringify([String(url), normalize(init)])).then(function (raw) {
      return new Response(typeof raw === 'string' ? JSON.parse(raw) : raw);
    });
  }

  function fetchText(url, init, encoding) {
    var req = normalize(init);
    req.encoding = encoding || null;
    return send('tv_fetch', JSON.stringify([String(url), req])).then(function (raw) {
      var r = new Response(typeof raw === 'string' ? JSON.parse(raw) : raw);
      return r.ok ? r._body : '';
    })['catch'](function () { return ''; });
  }

  var NovelStatus = {
    Unknown: 'Unknown', Ongoing: 'Ongoing', Completed: 'Completed', Licensed: 'Licensed',
    PublishingFinished: 'Publishing Finished', Cancelled: 'Cancelled', OnHiatus: 'On Hiatus',
    STUB: 'STUB', Inactive: 'Inactive',
  };
  var FilterTypes = {
    TextInput: 'Text', Picker: 'Picker', CheckboxGroup: 'Checkbox', Switch: 'Switch',
    ExcludableCheckboxGroup: 'XCheckbox',
  };
  var defaultCover =
    'https://github.com/lnreader/lnreader-plugins/blob/master/public/static/coverNotAvailable.webp?raw=true';
  // From lnreader-plugins src/lib/utils.ts (MIT).
  var isUrlAbsolute = function (url) {
    if (url) {
      if (url.indexOf('//') === 0) return true;
      if (url.indexOf('://') === -1) return false;
      if (url.indexOf('.') === -1) return false;
      if (url.indexOf('/') === -1) return false;
      if (url.indexOf(':') > url.indexOf('/')) return false;
      if (url.indexOf('://') < url.indexOf('.')) return true;
    }
    return false;
  };

  // The plugin's own storage: Dart files it under the plugin whose context
  // this is.
  function storageFor() {
    var call = function (op, args) {
      return send('tv_storage', JSON.stringify([op].concat(args || [])));
    };
    return {
      storage: {
        get: function (key, raw) {
          var s = call('get', [key]);
          if (s == null || s === '') return undefined;
          var item = JSON.parse(s);
          if (item == null) return undefined;
          if (item.expires && Date.now() > item.expires) { call('delete', [key]); return undefined; }
          return raw ? item : item.value;
        },
        set: function (key, value, expires) {
          call('set', [key, JSON.stringify({
            created: new Date(), value: value,
            expires: expires instanceof Date ? expires.getTime() : expires,
          })]);
        },
        'delete': function (key) { call('delete', [key]); },
        clearAll: function () { call('clearAll', []); },
        getAllKeys: function () { return JSON.parse(call('keys', []) || '[]'); },
      },
      localStorage: { get: function () { return undefined; } },
      sessionStorage: { get: function () { return undefined; } },
    };
  }

  var packages = {
    'htmlparser2': L.htmlparser2,
    'cheerio': L.cheerio,
    'dayjs': L.dayjs,
    'urlencode': { encode: encodeURIComponent, decode: decodeURIComponent },
    '@libs/fetch': { fetchApi: fetchApi, fetchText: fetchText },
    '@libs/novelStatus': { NovelStatus: NovelStatus },
    '@libs/isAbsoluteUrl': { isUrlAbsolute: isUrlAbsolute },
    '@libs/filterInputs': { FilterTypes: FilterTypes },
    '@libs/defaultCover': { defaultCover: defaultCover },
    // NovelFire and NovelPhoenix were built reading this path.
    '@/types/constants': { defaultCover: defaultCover, NovelStatus: NovelStatus },
  };

  g.Headers = Headers;
  g.FormData = FormData;
  g.Response = Response;
  g.fetch = fetchApi;

  var plugins = {};

  // Load a plugin's code; returns what TomeVoice needs to know about it.
  g.__tvLoadPlugin = function (pluginId, code) {
    var req = function (name) {
      if (name === '@libs/storage') return storageFor();
      var lib = packages[name];
      if (lib === undefined) throw new Error('This source needs "' + name + '", which TomeVoice does not have yet.');
      return lib;
    };
    var plugin = Function('require', 'module',
      'var exports = module.exports = {};\n' + code + '\n;return exports.default')(req, {});
    if (!plugin || typeof plugin.popularNovels !== 'function') throw new Error('Not an LNReader source plugin.');
    plugins[pluginId] = plugin;
    return JSON.stringify({
      id: plugin.id, name: plugin.name, site: plugin.site, version: plugin.version,
      filters: plugin.filters || null, pluginSettings: plugin.pluginSettings || null,
      imageRequestInit: plugin.imageRequestInit || null,
      hasParsePage: typeof plugin.parsePage === 'function',
      hasResolveUrl: typeof plugin.resolveUrl === 'function',
    });
  };

  g.__tvHasPlugin = function (pluginId) { return pluginId in plugins; };

  // Call a plugin method; resolves to its result as JSON.
  g.__tvCall = function (pluginId, method, argsJson) {
    var p = plugins[pluginId];
    if (!p) return Promise.reject(new Error('Source ' + pluginId + ' is not loaded.'));
    var args = JSON.parse(argsJson);
    // Popular with no filters chosen: the plugin's own defaults, which every
    // definition carries (some plugins read them without a fallback).
    if (method === 'popularNovels' && args[1] && args[1].filters == null) {
      args[1].filters = p.filters || {};
    }
    if (method === 'resolveUrl') {
      var path = args[0];
      if (isUrlAbsolute(path)) return Promise.resolve(JSON.stringify(path));
      if (typeof p.resolveUrl === 'function') return Promise.resolve(JSON.stringify(p.resolveUrl(path, args[1])));
      return Promise.resolve(JSON.stringify(p.site + path));
    }
    return Promise.resolve(p[method].apply(p, args)).then(function (r) {
      return JSON.stringify(r === undefined ? null : r);
    });
  };
})();
