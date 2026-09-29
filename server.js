'use strict';
// Serves the seating chart page. The guest list itself lives in Supabase,
// so this server has no data and no secrets. It only hands out the page.
const http = require('http');
const fs = require('fs');
const path = require('path');
const zlib = require('zlib');
const crypto = require('crypto');

const PORT = Number(process.env.PORT) || 3000;
const SUPABASE = 'https://bwmtsiskztrowezcoipo.supabase.co';

const ROUTES = {
  '/': { file: 'index.html', type: 'text/html; charset=utf-8', cache: 'no-cache' },
  '/index.html': { file: 'index.html', type: 'text/html; charset=utf-8', cache: 'no-cache' },
  '/icon.svg': { file: 'icon.svg', type: 'image/svg+xml', cache: 'public, max-age=86400' },
  '/apple-touch-icon.png': { file: 'apple-touch-icon.png', type: 'image/png', cache: 'public, max-age=86400' },
  '/apple-touch-icon-precomposed.png': { file: 'apple-touch-icon.png', type: 'image/png', cache: 'public, max-age=86400' },
  '/favicon.ico': { file: 'apple-touch-icon.png', type: 'image/png', cache: 'public, max-age=86400' }
};

const CSP = [
  "default-src 'none'",
  "script-src 'unsafe-inline'",
  "style-src 'unsafe-inline' https://fonts.googleapis.com",
  'font-src https://fonts.gstatic.com',
  "img-src 'self' data: blob:",
  'connect-src ' + SUPABASE,
  "base-uri 'none'",
  "form-action 'none'",
  "frame-ancestors 'none'"
].join('; ');

const COMMON = {
  'Content-Security-Policy': CSP,
  'X-Robots-Tag': 'noindex, nofollow',
  'Referrer-Policy': 'no-referrer',
  'X-Content-Type-Options': 'nosniff',
  'Permissions-Policy': 'camera=(), microphone=(), geolocation=()'
};

// Read every file once at startup, with a gzip copy for text.
const FILES = {};
for (const r of Object.values(ROUTES)) {
  if (FILES[r.file]) continue;
  const body = fs.readFileSync(path.join(__dirname, r.file));
  const text = /^(text|image\/svg)/.test(r.type);
  FILES[r.file] = {
    body,
    gz: text ? zlib.gzipSync(body, { level: 9 }) : null,
    etag: '"' + crypto.createHash('sha1').update(body).digest('base64url').slice(0, 20) + '"'
  };
}

function send(res, status, headers, body) {
  res.writeHead(status, Object.assign({}, COMMON, headers));
  res.end(body);
}

http.createServer((req, res) => {
  const url = (req.url || '/').split('?')[0];
  if (req.method !== 'GET' && req.method !== 'HEAD') {
    return send(res, 405, { Allow: 'GET, HEAD', 'Content-Type': 'text/plain' }, 'Method not allowed');
  }
  if (url === '/healthz') return send(res, 200, { 'Content-Type': 'text/plain', 'Cache-Control': 'no-store' }, 'ok');
  if (url === '/robots.txt') return send(res, 200, { 'Content-Type': 'text/plain' }, 'User-agent: *\nDisallow: /\n');
  const route = ROUTES[url];
  if (!route) return send(res, 404, { 'Content-Type': 'text/plain; charset=utf-8' }, 'Not found');
  const f = FILES[route.file];
  const headers = { 'Content-Type': route.type, 'Cache-Control': route.cache, ETag: f.etag, Vary: 'Accept-Encoding' };
  if (req.headers['if-none-match'] === f.etag) return send(res, 304, headers);
  let body = f.body;
  if (f.gz && /\bgzip\b/.test(req.headers['accept-encoding'] || '')) {
    body = f.gz;
    headers['Content-Encoding'] = 'gzip';
  }
  headers['Content-Length'] = body.length;
  send(res, 200, headers, req.method === 'HEAD' ? undefined : body);
}).listen(PORT, '0.0.0.0', () => {
  console.log('Seating chart listening on port ' + PORT);
});
