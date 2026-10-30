// What a few LNReader plugins need beyond the main bundle (entry.js), at the
// versions the LNReader app hands them (src/plugins/pluginManager.ts):
// protobufjs for @libs/fetch's fetchProto (gRPC-web sites such as
// WuxiaWorld), and @noble/ciphers for @libs/aes and @libs/utils. Kept apart
// and loaded only by the plugins that ask for them, so every other source's
// context starts no slower.
import './textcodec.js';
import { parse } from 'protobufjs';
import { gcm } from '@noble/ciphers/aes.js';
import { utf8ToBytes, bytesToUtf8 } from '@noble/ciphers/utils.js';

globalThis.__tvExtra = { parseProto: parse, gcm, utf8ToBytes, bytesToUtf8 };
