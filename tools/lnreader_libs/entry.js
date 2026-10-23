// The libraries the LNReader app hands its plugins (src/plugins/pluginManager.ts),
// at the same versions, so plugins behave here as they do there.
import './atob.js';
import 'core-js/actual/url';
import 'core-js/actual/url-search-params';
import { load } from 'cheerio';
import { Parser } from 'htmlparser2';
import dayjs from 'dayjs';
import localizedFormat from 'dayjs/plugin/localizedFormat';
import calendar from 'dayjs/plugin/calendar';

dayjs.extend(localizedFormat);
dayjs.extend(calendar);
globalThis.__tvLibs = { cheerio: { load }, htmlparser2: { Parser }, dayjs };
