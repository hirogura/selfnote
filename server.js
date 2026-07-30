const http = require('http');
const fs = require('fs');
const fsp = fs.promises;
const path = require('path');
const { URL } = require('url');

const PORT = 3342;
const HOST = '127.0.0.1';
const DATA = '/opt/lxd-data/note';
const PUB = path.join(__dirname, 'public');
const FAVORITES_FILE = path.join(DATA, '.favorites.json');

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

function safe(p) {
  const real = path.resolve(p);
  return real.startsWith(DATA) || real.startsWith(PUB);
}

function readBody(req) {
  return new Promise(r => {
    const c = [];
    req.on('data', d => c.push(d));
    req.on('end', () => r(Buffer.concat(c).toString()));
  });
}

const dirCache = new Map();
const CACHE_TTL = 2000;

async function listDir(dir) {
  const cached = dirCache.get(dir);
  if (cached && Date.now() - cached.ts < CACHE_TTL) return cached.items;
  try {
    const entries = await fsp.readdir(dir, { withFileTypes: true });
    const items = await Promise.all(entries.map(async d => {
      try {
        const st = await fsp.stat(path.join(dir, d.name));
        return { name: d.name, isDir: d.isDirectory(), birthtime: st.birthtimeMs || 0 };
      } catch { return { name: d.name, isDir: d.isDirectory(), birthtime: 0 }; }
    }));
    items.sort((a, b) => a.isDir !== b.isDir ? (a.isDir ? -1 : 1) : a.name.localeCompare(b.name));
    dirCache.set(dir, { items, ts: Date.now() });
    return items;
  } catch { return []; }
}

function invalidateCache() { dirCache.clear(); }

const server = http.createServer(async (req, res) => {
  const url = new URL(req.url, `http://${req.headers.host}`);
  const pn = decodeURIComponent(url.pathname);

  if (pn === '/api/files' && req.method === 'GET')
    return json(res, 200, await listDir(DATA));

  if (pn.startsWith('/api/files/') && req.method === 'GET') {
    const rel = pn.slice(11), fp = path.join(DATA, rel);
    if (!safe(fp)) return json(res, 403, { error: 'denied' });
    if (!fs.existsSync(fp)) return json(res, 404, { error: 'not found' });
    if (fs.statSync(fp).isDirectory()) return json(res, 200, await listDir(fp));
    return json(res, 200, { content: await fsp.readFile(fp, 'utf-8'), path: rel });
  }

  if (pn === '/api/files' && req.method === 'POST') {
    const b = JSON.parse(await readBody(req));
    const fp = path.join(b.parent || '', b.name);
    const full = path.join(DATA, fp);
    if (!safe(full)) return json(res, 403, { error: 'denied' });
    if (fs.existsSync(full)) return json(res, 409, { error: 'exists' });
    if (b.isDir) fs.mkdirSync(full, { recursive: true });
    else { fs.mkdirSync(path.dirname(full), { recursive: true }); fs.writeFileSync(full, ''); }
    invalidateCache();
    return json(res, 200, { ok: true, path: fp });
  }

  if (pn.startsWith('/api/files/') && req.method === 'PUT') {
    const fp = pn.slice(11), full = path.join(DATA, fp);
    if (!safe(full)) return json(res, 403, { error: 'denied' });
    fs.mkdirSync(path.dirname(full), { recursive: true });
    const body = JSON.parse(await readBody(req));
    fs.writeFileSync(full, body.content || '', 'utf-8');
    invalidateCache();
    return json(res, 200, { ok: true });
  }

  if (pn.startsWith('/api/files/') && req.method === 'DELETE') {
    const fp = pn.slice(11), full = path.join(DATA, fp);
    if (!safe(full)) return json(res, 403, { error: 'denied' });
    if (!fs.existsSync(fp)) return json(res, 404, { error: 'not found' });
    fs.rmSync(full, { recursive: true });
    invalidateCache();
    return json(res, 200, { ok: true });
  }

  if (pn === '/api/rename' && req.method === 'POST') {
    const b = JSON.parse(await readBody(req));
    const o = path.join(DATA, b.old), n = path.join(path.dirname(o), b.newName);
    if (!safe(o) || !safe(n)) return json(res, 403, { error: 'denied' });
    if (fs.existsSync(n)) return json(res, 409, { error: 'exists' });
    fs.renameSync(o, n);
    invalidateCache();
    return json(res, 200, { ok: true, path: path.relative(DATA, n) });
  }

  if (pn === '/api/move' && req.method === 'POST') {
    const b = JSON.parse(await readBody(req));
    const src = path.join(DATA, b.from);
    if (!safe(src) || !fs.existsSync(src)) return json(res, 404, { error: 'not found' });
    const dest = path.join(DATA, b.to, path.basename(b.from));
    if (!safe(dest)) return json(res, 403, { error: 'denied' });
    if (fs.existsSync(dest)) return json(res, 409, { error: 'exists' });
    fs.mkdirSync(path.dirname(dest), { recursive: true });
    fs.renameSync(src, dest);
    invalidateCache();
    return json(res, 200, { ok: true, path: path.relative(DATA, dest) });
  }

  if (pn === '/api/favorites' && req.method === 'GET') {
    try {
      const data = fs.readFileSync(FAVORITES_FILE, 'utf-8');
      return json(res, 200, JSON.parse(data));
    } catch { return json(res, 200, []); }
  }

  if (pn === '/api/favorites' && req.method === 'POST') {
    const b = JSON.parse(await readBody(req));
    fs.writeFileSync(FAVORITES_FILE, JSON.stringify(b.favorites || [], null, 2), 'utf-8');
    return json(res, 200, { ok: true });
  }

  if (pn === '/api/search' && req.method === 'POST') {
    const b = JSON.parse(await readBody(req));
    const q = (b.query || '').toLowerCase();
    if (!q) return json(res, 200, []);
    const results = [];
    async function searchDir(dir, base) {
      try {
        for (const f of await fsp.readdir(dir, { withFileTypes: true })) {
          const fp = path.join(dir, f.name);
          const rel = base ? base + '/' + f.name : f.name;
          if (f.isDirectory()) { await searchDir(fp, rel); continue; }
          if (!f.name.endsWith('.md')) continue;
          try {
            const content = await fsp.readFile(fp, 'utf-8');
            const lines = content.split('\n');
            for (let i = 0; i < lines.length; i++) {
              if (lines[i].toLowerCase().includes(q)) {
                results.push({ file: rel, line: i + 1, text: lines[i].trim() });
                break;
              }
            }
          } catch {}
        }
      } catch {}
    }
    await searchDir(DATA, '');
    return json(res, 200, results);
  }

  let fp = pn === '/' ? '/index.html' : pn;
  fp = path.join(PUB, fp);
  if (!fs.existsSync(fp) || fs.statSync(fp).isDirectory()) fp = path.join(PUB, 'index.html');
  try {
    const data = fs.readFileSync(fp);
    res.writeHead(200, { 'Content-Type': MIME[path.extname(fp)] || 'application/octet-stream' });
    res.end(data);
  } catch { res.writeHead(404); res.end('Not found'); }
});

server.on('error', (err) => {
  console.error('Server error:', err.code, err.message);
  process.exit(1);
});

server.listen(PORT, HOST, () => console.log(`SelfNote: http://${HOST}:${PORT}`));
