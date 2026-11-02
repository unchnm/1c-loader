import * as fs from 'fs';
import * as os from 'os';
import * as path from 'path';
import { Infobase } from './types';

export function ibasesFilePath(): string {
  const appData = process.env.APPDATA || path.join(os.homedir(), 'AppData', 'Roaming');
  return path.join(appData, '1C', '1CEStart', 'ibases.v8i');
}

export function decodeIbases(buf: Buffer): string | null {
  if (buf.length >= 2 && buf[0] === 0xff && buf[1] === 0xfe) {
    return buf.subarray(2).toString('utf16le');
  }
  if (buf.length >= 2 && buf[0] === 0xfe && buf[1] === 0xff) {
    const swapped = Buffer.alloc(buf.length - 2);
    for (let i = 2; i + 1 < buf.length; i += 2) {
      swapped[i - 2] = buf[i + 1];
      swapped[i - 1] = buf[i];
    }
    return swapped.toString('utf16le');
  }
  if (buf.length >= 3 && buf[0] === 0xef && buf[1] === 0xbb && buf[2] === 0xbf) {
    return buf.subarray(3).toString('utf8');
  }
  if (buf.includes(0)) {
    const text = buf.toString('utf16le');
    if (/^\[/m.test(text)) {
      return text;
    }
  }
  const utf8 = buf.toString('utf8');
  if (/^\[/m.test(utf8)) {
    return utf8;
  }
  try {
    const text = new TextDecoder('windows-1251').decode(buf);
    if (/^\[/m.test(text)) {
      return text;
    }
  } catch {
    // windows-1251 недоступен — оставляем utf-8
  }
  return null;
}

export function parseIbases(content: string): Infobase[] {
  const list: Infobase[] = [];
  let cur: Infobase | null = null;
  const push = () => {
    if (cur && (cur.server || cur.filePath)) {
      list.push(cur);
    }
  };
  for (const raw of content.split(/\r?\n/)) {
    const line = raw.trim();
    if (!line) {
      continue;
    }
    const header = /^\[(.+)\]$/.exec(line);
    if (header) {
      push();
      cur = {
        name: header[1].trim(),
        server: '',
        ref: '',
        filePath: '',
        isServer: false,
        version: '',
        defaultVersion: ''
      };
      continue;
    }
    if (!cur) {
      continue;
    }
    const connect = /^Connect\s*=\s*(.+)$/i.exec(line);
    if (connect) {
      const conn = connect[1].replace(/;$/, '');
      const srvr = /Srvr\s*=\s*"([^"]*)"/i.exec(conn);
      const ref = /Ref\s*=\s*"([^"]*)"/i.exec(conn);
      const file = /File\s*=\s*"([^"]*)"/i.exec(conn);
      if (srvr) {
        cur.server = srvr[1];
        cur.isServer = true;
      }
      if (ref) {
        cur.ref = ref[1];
      }
      if (file) {
        cur.filePath = file[1];
      }
      continue;
    }
    const ver = /^Version\s*=\s*(.+)$/i.exec(line);
    if (ver) {
      cur.version = ver[1].trim();
      continue;
    }
    const def = /^DefaultVersion\s*=\s*(.+)$/i.exec(line);
    if (def) {
      cur.defaultVersion = def[1].trim();
    }
  }
  push();
  return list;
}

export function readIbases(filePath: string = ibasesFilePath()): Infobase[] | null {
  if (!fs.existsSync(filePath)) {
    return null;
  }
  const text = decodeIbases(fs.readFileSync(filePath));
  if (!text) {
    return null;
  }
  return parseIbases(text);
}

export function infobaseLabel(base: Infobase): string {
  if (base.isServer) {
    return `${base.name}   [${base.server} / ${base.ref}]`;
  }
  return `${base.name}   [${base.filePath}]`;
}

export function platformVersionOf(base: Infobase): string | null {
  if (base.defaultVersion) {
    return base.defaultVersion.trim();
  }
  if (base.version) {
    return base.version.trim();
  }
  return null;
}

export function connectionToken(base: Infobase): string {
  if (base.isServer) {
    return `${base.server}\\${base.ref}`;
  }
  return base.filePath;
}
