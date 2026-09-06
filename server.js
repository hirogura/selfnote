const http = require('http');
const fs = require('fs');
const fsp = fs.promises;
const path = require('path');
const { URL } = require('url');
const { exec } = require('child_process');

const PORT = 3342;
const HOST = '127.0.0.1';
const DATA = '/opt/lxd-data/note';
const PUB = path.join(__dirname, 'public');
const FAVORITES_FILE = path.join(DATA, '.favorites.json');
const UPDATE_FLAG = '/tmp/selfnote-update.flag';
const MAX_BODY = 5 * 1024 * 1024;
const MAX_SEARCH_QUERY = 200;
const MAX_SEARCH_RESULTS = 50;
const MAX_SEARCH_FILE = 1024 * 1024;
const MAX_RECENT = 100;

try { fs.unlinkSync(UPDATE_FLAG); } catch {}

const MIME = {
  '.html': 'text/html; charset=utf-8',
  '.css': 'text/css; charset=utf-8',
  '.js': 'application/javascript; charset=utf-8',
  '.json': 'application/json; charset=utf-8',
  '.png': 'image/png', '.jpg': 'image/jpeg', '.gif': 'image/gif',
  '.svg': 'image/svg+xml', '.ico': 'image/x-icon',
};

function json(res, code, data) {
  res.writeHead(code, { 'Content-Type': 'application/json; charset=utf-8' });
  res.end(JSON.stringify(data));
}

function isInside(real, base) {
  const rel = path.relative(base, real);
  return rel === '' || (!rel.startsWith('..') && !path.isAbsolute(rel));
}

function safeData(p) {
  return isInside(path.resolve(p), DATA);
}

function safePub(p) {
  return isInside(path.resolve(p), PUB);
}

function safe(p) {
  const real = path.resolve(p);
  return isInside(real, DATA) || isInside(real, PUB);
}

function readBody(req) {
  return new Promise((resolve, reject) => {
    const c = [];
    let size = 0;
    req.on('data', d => {
      size += d.length;
      if (size > MAX_BODY) {
        reject(new Error('body too large'));
        req.destroy();
        return;
      }
      c.push(d);
    });
    req.on('end', () => resolve(Buffer.concat(c).toString()));
    req.on('error', reject);
  });
}

function parseJson(text) {
  if (!text) return null;
  try { return JSON.parse(text); } catch { return undefined; }
}

function validSegment(name) {
  if (typeof name !== 'string') return false;
  const t = name.trim();
  if (!t || t === '.' || t === '..') return false;
  if (t.includes('/') || t.includes('\\') || t.includes('\0')) return false;
  return true;
}

function validRel(rel) {
  if (rel === '' || rel === undefined || rel === null) return true;
  if (typeof rel !== 'string') return false;
  if (rel.includes('\0')) return false;
  if (path.isAbsolute(rel)) return false;
  const parts = rel.split('/');
  for (const p of parts) {
    if (p === '..' || p.includes('\\')) return false;
  }
  return true;
}

const dirCache = new Map();
const CACHE_TTL = 2000;

function fileTimes(st) {
  return {
    birthtime: st.birthtimeMs || st.mtimeMs || st.ctimeMs || 0,
    mtime: st.mtimeMs || 0,
  };
}

async function listDir(dir) {
  const cached = dirCache.get(dir);
  if (cached && Date.now() - cached.ts < CACHE_TTL) return cached.items;
  try {
    const entries = await fsp.readdir(dir, { withFileTypes: true });
    const items = await Promise.all(entries.map(async d => {
      try {
        const st = await fsp.stat(path.join(dir, d.name));
        return { name: d.name, isDir: d.isDirectory(), ...fileTimes(st) };
      } catch { return { name: d.name, isDir: d.isDirectory(), birthtime: 0, mtime: 0 }; }
    }));
    items.sort((a, b) => a.isDir !== b.isDir ? (a.isDir ? -1 : 1) : a.name.localeCompare(b.name));
    dirCache.set(dir, { items, ts: Date.now() });
    return items;
  } catch { return []; }
}

function invalidateCache() { dirCache.clear(); }

const server = http.createServer(async (req, res) => {
  let url;
  try {
    url = new URL(req.url, `http://${req.headers.host || '127.0.0.1'}`);
  } catch {
    return json(res, 400, { error: 'bad request' });
  }
  let pn;
  try {
    pn = decodeURIComponent(url.pathname);
  } catch {
    return json(res, 400, { error: 'bad request' });
  }

  try {
    if (pn === '/api/files' && req.method === 'GET')
      return json(res, 200, await listDir(DATA));

    if (pn.startsWith('/api/files/') && req.method === 'GET') {
      const rel = pn.slice(11);
      if (!rel || !validRel(rel)) return json(res, 403, { error: 'denied' });
      const fp = path.join(DATA, rel);
      if (!safeData(fp)) return json(res, 403, { error: 'denied' });
      let st;
      try { st = await fsp.stat(fp); } catch { return json(res, 404, { error: 'not found' }); }
      if (st.isDirectory()) {
        if (!isInside(path.resolve(fp), DATA)) return json(res, 403, { error: 'denied' });
        return json(res, 200, await listDir(fp));
      }
      try {
        const content = await fsp.readFile(fp, 'utf-8');
        return json(res, 200, { content, path: rel });
      } catch { return json(res, 404, { error: 'not found' }); }
    }

    if (pn === '/api/files' && req.method === 'POST') {
      let b;
      try { b = parseJson(await readBody(req)); } catch { return json(res, 413, { error: 'body too large' }); }
      if (b === undefined || b === null) return json(res, 400, { error: 'bad json' });
      const parent = b.parent || '';
      if (!validRel(parent) || !validSegment(b.name)) return json(res, 400, { error: 'bad name' });
      const fp = path.join(parent, b.name);
      const full = path.join(DATA, fp);
      if (!safeData(full)) return json(res, 403, { error: 'denied' });
      if (path.resolve(full) === path.resolve(DATA)) return json(res, 400, { error: 'bad name' });
      try {
        if (fs.existsSync(full)) return json(res, 409, { error: 'exists' });
        if (b.isDir) fs.mkdirSync(full, { recursive: true });
        else { fs.mkdirSync(path.dirname(full), { recursive: true }); fs.writeFileSync(full, ''); }
      } catch { return json(res, 500, { error: 'create failed' }); }
      invalidateCache();
      return json(res, 200, { ok: true, path: fp });
    }

    if (pn.startsWith('/api/files/') && req.method === 'PUT') {
      const fp = pn.slice(11);
      if (!fp || !validRel(fp)) return json(res, 400, { error: 'bad path' });
      const full = path.join(DATA, fp);
      if (!safeData(full)) return json(res, 403, { error: 'denied' });
      if (path.resolve(full) === path.resolve(DATA)) return json(res, 400, { error: 'bad path' });
      let body;
      try { body = parseJson(await readBody(req)); } catch { return json(res, 413, { error: 'body too large' }); }
      if (body === undefined || body === null) return json(res, 400, { error: 'bad json' });
      try {
        let st = null;
        try { st = fs.statSync(full); } catch {}
        if (st && st.isDirectory()) return json(res, 400, { error: 'is directory' });
        fs.mkdirSync(path.dirname(full), { recursive: true });
        fs.writeFileSync(full, body.content || '', 'utf-8');
      } catch { return json(res, 500, { error: 'write failed' }); }
      invalidateCache();
      return json(res, 200, { ok: true });
    }

    if (pn.startsWith('/api/files/') && req.method === 'DELETE') {
      const fp = pn.slice(11);
      if (!fp || !validRel(fp)) return json(res, 400, { error: 'bad path' });
      const full = path.join(DATA, fp);
      if (!safeData(full)) return json(res, 403, { error: 'denied' });
      if (path.resolve(full) === path.resolve(DATA)) return json(res, 400, { error: 'bad path' });
      try {
        if (!fs.existsSync(full)) return json(res, 404, { error: 'not found' });
        fs.rmSync(full, { recursive: true });
      } catch { return json(res, 500, { error: 'delete failed' }); }
      invalidateCache();
      return json(res, 200, { ok: true });
    }

    if (pn === '/api/rename' && req.method === 'POST') {
      let b;
      try { b = parseJson(await readBody(req)); } catch { return json(res, 413, { error: 'body too large' }); }
      if (!b || typeof b.old !== 'string' || !validRel(b.old) || !b.old) return json(res, 400, { error: 'bad request' });
      if (!validSegment(b.newName)) return json(res, 400, { error: 'bad name' });
      const o = path.join(DATA, b.old);
      const n = path.join(path.dirname(o), b.newName.trim());
      if (!safeData(o) || !safeData(n)) return json(res, 403, { error: 'denied' });
      if (path.resolve(o) === path.resolve(DATA)) return json(res, 400, { error: 'bad path' });
      try {
        if (!fs.existsSync(o)) return json(res, 404, { error: 'not found' });
        if (fs.existsSync(n)) return json(res, 409, { error: 'exists' });
        fs.renameSync(o, n);
      } catch { return json(res, 500, { error: 'rename failed' }); }
      invalidateCache();
      return json(res, 200, { ok: true, path: path.relative(DATA, n) });
    }

    if (pn === '/api/move' && req.method === 'POST') {
      let b;
      try { b = parseJson(await readBody(req)); } catch { return json(res, 413, { error: 'body too large' }); }
      if (!b || typeof b.from !== 'string' || !b.from || !validRel(b.from)) return json(res, 400, { error: 'bad request' });
      const to = b.to || '';
      if (typeof to !== 'string' || !validRel(to)) return json(res, 400, { error: 'bad request' });
      const src = path.join(DATA, b.from);
      if (!safeData(src)) return json(res, 403, { error: 'denied' });
      if (path.resolve(src) === path.resolve(DATA)) return json(res, 400, { error: 'bad path' });
      let srcStat;
      try { srcStat = fs.statSync(src); } catch { return json(res, 404, { error: 'not found' }); }
      const destDir = path.join(DATA, to);
      const dest = path.join(destDir, path.basename(b.from));
      if (!safeData(destDir) || !safeData(dest)) return json(res, 403, { error: 'denied' });
      const rSrc = path.resolve(src);
      const rDest = path.resolve(dest);
      const rDestDir = path.resolve(destDir);
      if (rSrc === rDest) return json(res, 409, { error: 'exists' });
      if (rDest === path.resolve(DATA) || rDestDir === rSrc || rDest.startsWith(rSrc + path.sep) || rDestDir.startsWith(rSrc + path.sep)) {
        return json(res, 400, { error: 'cannot move into itself' });
      }
      try {
        if (fs.existsSync(dest)) return json(res, 409, { error: 'exists' });
        let destStat = null;
        try { destStat = fs.statSync(destDir); } catch {}
        if (destStat && !destStat.isDirectory()) return json(res, 400, { error: 'bad destination' });
        void srcStat;
        fs.mkdirSync(path.dirname(dest), { recursive: true });
        fs.renameSync(src, dest);
      } catch { return json(res, 500, { error: 'move failed' }); }
      invalidateCache();
      return json(res, 200, { ok: true, path: path.relative(DATA, dest) });
    }

    if (pn === '/api/favorites' && req.method === 'GET') {
      try {
        const data = fs.readFileSync(FAVORITES_FILE, 'utf-8');
        const parsed = JSON.parse(data);
        if (!Array.isArray(parsed)) return json(res, 200, []);
        return json(res, 200, parsed.filter(x => typeof x === 'string').slice(0, 500));
      } catch { return json(res, 200, []); }
    }

    if (pn === '/api/favorites' && req.method === 'POST') {
      let b;
      try { b = parseJson(await readBody(req)); } catch { return json(res, 413, { error: 'body too large' }); }
      if (!b || !Array.isArray(b.favorites)) return json(res, 400, { error: 'bad request' });
      const favs = b.favorites.filter(x => typeof x === 'string' && x && validRel(x)).slice(0, 500);
      try {
        fs.mkdirSync(DATA, { recursive: true });
        fs.writeFileSync(FAVORITES_FILE, JSON.stringify(favs, null, 2), 'utf-8');
      } catch { return json(res, 500, { error: 'write failed' }); }
      return json(res, 200, { ok: true });
    }

    if (pn === '/api/restart' && req.method === 'POST') {
      json(res, 200, { ok: true });
      setTimeout(() => exec('systemctl restart selfnote'), 200);
      return;
    }

    if (pn === '/api/update' && req.method === 'POST') {
      let busy = false;
      try { if (Date.now() - fs.statSync(UPDATE_FLAG).mtimeMs < 15 * 60 * 1000) busy = true; } catch {}
      if (busy) return json(res, 409, { ok: false, error: 'updating' });
      try { fs.writeFileSync(UPDATE_FLAG, String(Date.now())); } catch {}
      json(res, 200, { ok: true });
      setTimeout(() => {
        const script = 'curl -fsSL https://raw.githubusercontent.com/hirogura/selfnote/main/install-selfnote.sh | bash';
        const hasSystemdRun = fs.existsSync('/usr/bin/systemd-run') || fs.existsSync('/bin/systemd-run');
        const cmd = hasSystemdRun
          ? `systemctl reset-failed selfnote-update 2>/dev/null; systemd-run --unit=selfnote-update --collect bash -c '${script}'`
          : `setsid bash -c "trap '' TERM HUP INT; ${script}" </dev/null >>/tmp/selfnote-update.log 2>&1 &`;
        exec(cmd);
      }, 100);
      return;
    }

    if (pn === '/api/update/status' && req.method === 'GET') {
      let updating = false;
      try { fs.statSync(UPDATE_FLAG); updating = true; } catch {}
      return json(res, 200, { updating });
    }

    if (pn === '/api/update/status' && req.method === 'DELETE') {
      try { fs.unlinkSync(UPDATE_FLAG); } catch {}
      return json(res, 200, { ok: true });
    }

    if (pn === '/api/recent' && req.method === 'GET') {
      const files = [];
      async function walk(dir) {
        let entries;
        try { entries = await fsp.readdir(dir, { withFileTypes: true }); } catch { return; }
        for (const f of entries) {
          if (f.name.startsWith('.')) continue;
          const fp = path.join(dir, f.name);
          if (!safeData(fp)) continue;
          if (f.isDirectory()) { await walk(fp); continue; }
          if (!f.name.endsWith('.md')) continue;
          try {
            const st = await fsp.stat(fp);
            files.push({ path: path.relative(DATA, fp), mtime: st.mtimeMs || 0 });
          } catch {}
        }
      }
      await walk(DATA);
      files.sort((a, b) => b.mtime - a.mtime);
      return json(res, 200, files.slice(0, MAX_RECENT));
    }

    if (pn === '/api/search' && req.method === 'POST') {
      let b;
      try { b = parseJson(await readBody(req)); } catch { return json(res, 413, { error: 'body too large' }); }
      const raw = (b && b.query) || '';
      if (typeof raw !== 'string') return json(res, 400, { error: 'bad request' });
      const q = raw.toLowerCase().slice(0, MAX_SEARCH_QUERY);
      if (!q.trim()) return json(res, 200, []);
      const results = [];
      async function searchDir(dir, base) {
        if (results.length >= MAX_SEARCH_RESULTS) return;
        let entries;
        try { entries = await fsp.readdir(dir, { withFileTypes: true }); } catch { return; }
        for (const f of entries) {
          if (results.length >= MAX_SEARCH_RESULTS) break;
          if (f.name.startsWith('.')) continue;
          const fp = path.join(dir, f.name);
          if (!safeData(fp)) continue;
          const rel = base ? base + '/' + f.name : f.name;
          if (f.isDirectory()) { await searchDir(fp, rel); continue; }
          if (!f.name.endsWith('.md')) continue;
          try {
            const st = await fsp.stat(fp);
            if (st.size > MAX_SEARCH_FILE) continue;
            const content = await fsp.readFile(fp, 'utf-8');
            const lines = content.split('\n');
            for (let i = 0; i < lines.length; i++) {
              if (lines[i].toLowerCase().includes(q)) {
                results.push({ file: rel, line: i + 1, text: lines[i].trim().slice(0, 200) });
                break;
              }
            }
          } catch {}
        }
      }
      await searchDir(DATA, '');
      return json(res, 200, results);
    }

    let fp = pn === '/' ? '/index.html' : pn;
    let full = path.normalize(path.join(PUB, fp));
    if (!safePub(full)) return json(res, 403, { error: 'denied' });
    try {
      const st = fs.statSync(full);
      if (st.isDirectory()) full = path.join(PUB, 'index.html');
    } catch {
      full = path.join(PUB, 'index.html');
    }
    try {
      const data = fs.readFileSync(full);
      res.writeHead(200, { 'Content-Type': MIME[path.extname(full)] || 'application/octet-stream' });
      res.end(data);
    } catch { res.writeHead(404); res.end('Not found'); }
  } catch (e) {
    try { return json(res, 500, { error: 'internal' }); } catch {}
  }
});

server.on('error', (err) => {
  console.error('Server error:', err.code, err.message);
  process.exit(1);
});

server.listen(PORT, HOST, () => console.log('SelfNote: http://' + HOST + ':' + PORT));
