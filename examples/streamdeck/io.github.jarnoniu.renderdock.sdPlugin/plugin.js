// A Stream Deck key that shows how far along the render in front is.
//
// It reads RenderDock's local API on this computer (menu-bar icon -> Local API) and draws a ring with the
// percentage on every key that holds this action. Plain Node.js, nothing to install and nothing to build:
// the WebSocket to the Stream Deck application is spoken here directly, so that it does not depend on which
// Node.js the application ships.
//
//   node plugin.js --self-test     tries the whole thing against stand-ins for both ends; needs no Stream Deck
//
// NOT RUN ON A STREAM DECK YET. It follows Elgato's published plugin protocol and passes the self-test, which
// plays the application's part; whether the real application takes the manifest and draws the image as meant
// has not been seen by anyone. See README.md next to this folder.
'use strict';

const crypto = require('crypto');
const fs = require('fs');
const http = require('http');
const net = require('net');
const os = require('os');
const path = require('path');

const MINT = '#4FEDB0', AQUA = '#42C2FF', AMBER = '#FFBD45', CORAL = '#FF6E69', GREY = '#6B7280';
const DISCOVERY = path.join(os.homedir(), 'Library', 'Application Support', 'RenderDock', 'api.json');

// MARK: what a key shows

/** The picture for a key, as an SVG: a ring filled to the fraction, a number or a word in the middle. */
function keyImage(summary) {
  const state = summary ? summary.state || 'idle' : 'off';
  const focus = (summary && summary.focus) || {};
  let fraction = typeof focus.fraction === 'number' ? focus.fraction : null;
  if (fraction === null && summary && summary.top && typeof summary.top.fraction === 'number') fraction = summary.top.fraction;
  let color = GREY, big = '', small = '';
  if (state === 'off') { big = '–'; small = 'API off'; }
  else if (state === 'error') { color = CORAL; big = '!'; small = 'failed'; fraction = 1; }
  else if (state === 'waiting') { color = AMBER; big = '!'; small = 'needs you'; fraction = 1; }
  else if (state === 'done') { color = MINT; big = '✓'; small = 'done'; fraction = 1; }
  else if (state === 'working') {
    color = fraction === null ? AQUA : MINT;
    big = fraction === null ? '…' : String(Math.floor(fraction * 100));
    small = fraction === null ? 'working' : (focus.exact === false ? '≈ %' : '%');
  } else { big = '·'; small = 'idle'; fraction = 0; }
  const r = 54, around = 2 * Math.PI * r;
  const filled = fraction === null ? 0 : Math.max(0, Math.min(1, fraction)) * around;
  return '<svg xmlns="http://www.w3.org/2000/svg" width="144" height="144" viewBox="0 0 144 144">'
    + '<rect width="144" height="144" fill="#0B0D12"/>'
    + `<circle cx="72" cy="72" r="${r}" fill="none" stroke="#1F2430" stroke-width="12"/>`
    + `<circle cx="72" cy="72" r="${r}" fill="none" stroke="${color}" stroke-width="12" stroke-linecap="round" `
    + `stroke-dasharray="${filled.toFixed(1)} ${around.toFixed(1)}" transform="rotate(-90 72 72)"/>`
    + `<text x="72" y="84" text-anchor="middle" font-family="-apple-system,Helvetica,Arial,sans-serif" font-size="44" font-weight="700" fill="#F5F5F5">${big}</text>`
    + `<text x="72" y="106" text-anchor="middle" font-family="-apple-system,Helvetica,Arial,sans-serif" font-size="15" fill="#BDBDBD">${small}</text>`
    + '</svg>';
}

function dataURL(svg) { return 'data:image/svg+xml,' + encodeURIComponent(svg); }

// MARK: RenderDock's local API

function apiURL(given) {
  if (given) return given.replace(/\/$/, '');
  try { return JSON.parse(fs.readFileSync(DISCOVERY, 'utf8')).url.replace(/\/$/, ''); } catch (_) { return null; }
}

/** The summary of the state, or null when the API is not there. Never throws. */
function readSummary(base) {
  return new Promise((resolve) => {
    if (!base) return resolve(null);
    const request = http.get(base + '/v1/state', { timeout: 2000 }, (response) => {
      let body = '';
      response.setEncoding('utf8');
      response.on('data', (chunk) => { body += chunk; if (body.length > 4e6) request.destroy(); });
      response.on('end', () => { try { resolve(JSON.parse(body).summary || null); } catch (_) { resolve(null); } });
    });
    request.on('timeout', () => request.destroy());
    request.on('error', () => resolve(null));
  });
}

// MARK: a WebSocket client, as much of one as this needs (text frames, ping and pong, close)

class Socket {
  constructor(port, { onOpen, onText, onClose }) {
    this.buffer = Buffer.alloc(0);
    this.open = false;
    this.onText = onText;
    this.onClose = onClose || (() => {});
    const key = crypto.randomBytes(16).toString('base64');
    this.tcp = net.connect(port, '127.0.0.1', () => {
      this.tcp.write(`GET / HTTP/1.1\r\nHost: 127.0.0.1:${port}\r\nUpgrade: websocket\r\nConnection: Upgrade\r\n`
        + `Sec-WebSocket-Key: ${key}\r\nSec-WebSocket-Version: 13\r\n\r\n`);
    });
    this.tcp.on('data', (chunk) => {
      this.buffer = Buffer.concat([this.buffer, chunk]);
      if (!this.open) {
        const end = this.buffer.indexOf('\r\n\r\n');
        if (end < 0) return;
        const head = this.buffer.subarray(0, end).toString('latin1');
        const expected = crypto.createHash('sha1').update(key + '258EAFA5-E914-47DA-95CA-C5AB0DC85B11').digest('base64');
        if (!/^HTTP\/1\.1 101/.test(head) || !head.toLowerCase().includes('sec-websocket-accept: ' + expected.toLowerCase())) {
          this.tcp.destroy();
          return;
        }
        this.buffer = this.buffer.subarray(end + 4);
        this.open = true;
        onOpen();
      }
      this.frames();
    });
    this.tcp.on('close', () => this.onClose());
    this.tcp.on('error', () => {});
  }

  frames() {
    for (;;) {
      if (this.buffer.length < 2) return;
      const first = this.buffer[0], second = this.buffer[1];
      let length = second & 0x7F, at = 2;
      if (length === 126) { if (this.buffer.length < 4) return; length = this.buffer.readUInt16BE(2); at = 4; }
      else if (length === 127) { if (this.buffer.length < 10) return; length = Number(this.buffer.readBigUInt64BE(2)); at = 10; }
      const masked = (second & 0x80) !== 0;
      if (masked) at += 4;
      if (this.buffer.length < at + length) return;
      let payload = Buffer.from(this.buffer.subarray(at, at + length));
      if (masked) { const mask = this.buffer.subarray(at - 4, at); for (let i = 0; i < payload.length; i++) payload[i] ^= mask[i % 4]; }
      this.buffer = this.buffer.subarray(at + length);
      const opcode = first & 0x0F;
      if (opcode === 0x1) this.onText(payload.toString('utf8'));
      else if (opcode === 0x9) this.write(0xA, payload);
      else if (opcode === 0x8) { this.tcp.end(); return; }
    }
  }

  /** One frame from client to server: always masked, as the protocol asks of a client. */
  write(opcode, payload) {
    const mask = crypto.randomBytes(4);
    let head;
    if (payload.length < 126) head = Buffer.from([0x80 | opcode, 0x80 | payload.length]);
    else if (payload.length < 65536) { head = Buffer.alloc(4); head[0] = 0x80 | opcode; head[1] = 0x80 | 126; head.writeUInt16BE(payload.length, 2); }
    else { head = Buffer.alloc(10); head[0] = 0x80 | opcode; head[1] = 0x80 | 127; head.writeBigUInt64BE(BigInt(payload.length), 2); }
    const body = Buffer.from(payload);
    for (let i = 0; i < body.length; i++) body[i] ^= mask[i % 4];
    this.tcp.write(Buffer.concat([head, mask, body]));
  }

  send(object) { if (this.open) this.write(0x1, Buffer.from(JSON.stringify(object), 'utf8')); }
  close() { this.tcp.destroy(); }
}

// MARK: the plugin

/** Reads `-port 123 -pluginUUID x -registerEvent y -info {…}` as the Stream Deck application passes them. */
function launchArguments(argv) {
  const out = {};
  for (let i = 0; i + 1 < argv.length; i++) if (argv[i].startsWith('-')) out[argv[i].replace(/^-+/, '')] = argv[i + 1];
  return out;
}

function start({ port, pluginUUID, registerEvent, api, interval }) {
  const keys = new Set();
  let lastImage = null, timer = null;
  const socket = new Socket(Number(port), {
    onOpen() {
      socket.send({ event: registerEvent, uuid: pluginUUID });
      timer = setInterval(refresh, interval);
      refresh();
    },
    onText(text) {
      let message;
      try { message = JSON.parse(text); } catch (_) { return; }
      if (message.event === 'willAppear' && message.context) {
        keys.add(message.context);
        if (lastImage) socket.send({ event: 'setImage', context: message.context, payload: { image: lastImage, target: 0 } });
        else refresh();
      } else if (message.event === 'willDisappear' && message.context) {
        keys.delete(message.context);
      }
    },
    onClose() { if (timer) clearInterval(timer); },
  });

  async function refresh() {
    if (keys.size === 0) return;
    const image = dataURL(keyImage(await readSummary(apiURL(api))));
    if (image === lastImage) return;
    lastImage = image;
    for (const context of keys) socket.send({ event: 'setImage', context, payload: { image, target: 0 } });
  }
  return socket;
}

// MARK: trying it without a Stream Deck

/** Plays the Stream Deck application: takes the plugin's connection, checks how it registers, puts a key up, and reads what it is sent. */
function selfTest() {
  const received = [];
  const states = [{ state: 'working', focus: { fraction: 0.62, exact: true } }, { state: 'waiting' }];
  let step = 0, failed = null;
  const api = http.createServer((request, response) => {
    if (request.url !== '/v1/state') { response.statusCode = 404; return response.end(); }
    response.setHeader('Content-Type', 'application/json');
    response.end(JSON.stringify({ summary: states[Math.min(step, states.length - 1)] }));
  });
  const app = net.createServer((tcp) => {
    let buffer = Buffer.alloc(0), upgraded = false;
    const send = (object) => {
      const payload = Buffer.from(JSON.stringify(object), 'utf8');
      const head = payload.length < 126 ? Buffer.from([0x81, payload.length]) : Buffer.from([0x81, 126, payload.length >> 8, payload.length & 0xFF]);
      tcp.write(Buffer.concat([head, payload]));   // server to client: not masked
    };
    tcp.on('data', (chunk) => {
      buffer = Buffer.concat([buffer, chunk]);
      if (!upgraded) {
        const end = buffer.indexOf('\r\n\r\n');
        if (end < 0) return;
        const key = /sec-websocket-key: (.+)\r\n/i.exec(buffer.subarray(0, end + 2).toString('latin1'));
        const accept = crypto.createHash('sha1').update(key[1].trim() + '258EAFA5-E914-47DA-95CA-C5AB0DC85B11').digest('base64');
        tcp.write(`HTTP/1.1 101 Switching Protocols\r\nUpgrade: websocket\r\nConnection: Upgrade\r\nSec-WebSocket-Accept: ${accept}\r\n\r\n`);
        buffer = buffer.subarray(end + 4);
        upgraded = true;
      }
      for (;;) {
        if (buffer.length < 2) return;
        let length = buffer[1] & 0x7F, at = 2;
        if (length === 126) { if (buffer.length < 4) return; length = buffer.readUInt16BE(2); at = 4; }
        else if (length === 127) { if (buffer.length < 10) return; length = Number(buffer.readBigUInt64BE(2)); at = 10; }
        if ((buffer[1] & 0x80) === 0) { failed = 'a frame from the plugin was not masked'; return; }
        if (buffer.length < at + 4 + length) return;
        const mask = buffer.subarray(at, at + 4), payload = Buffer.from(buffer.subarray(at + 4, at + 4 + length));
        for (let i = 0; i < payload.length; i++) payload[i] ^= mask[i % 4];
        buffer = buffer.subarray(at + 4 + length);
        const message = JSON.parse(payload.toString('utf8'));
        received.push(message);
        if (message.event === 'register-me') send({ event: 'willAppear', action: 'io.github.jarnoniu.renderdock.progress', context: 'key-1', device: 'd', payload: { settings: {}, coordinates: { column: 0, row: 0 } } });
      }
    });
    tcp.on('error', () => {});
  });

  const until = (what, ms) => new Promise((resolve) => {
    const began = Date.now();
    const look = () => (what() || Date.now() - began > ms ? resolve(what()) : setTimeout(look, 20));
    look();
  });
  const svgOf = (message) => decodeURIComponent(message.payload.image.replace('data:image/svg+xml,', ''));

  api.listen(0, '127.0.0.1', () => app.listen(0, '127.0.0.1', async () => {
    const plugin = start({ port: app.address().port, pluginUUID: 'PLUGIN-1', registerEvent: 'register-me',
                           api: 'http://127.0.0.1:' + api.address().port, interval: 100 });
    const check = (name, ok) => { if (!ok && !failed) failed = name; };
    await until(() => received.length >= 2, 3000);
    check('registers first, with the event and the id it was given', received[0] && received[0].event === 'register-me' && received[0].uuid === 'PLUGIN-1');
    check('draws the key once it appears', received[1] && received[1].event === 'setImage' && received[1].context === 'key-1');
    check('the picture says 62 and is the colour of a render going well', received[1] && svgOf(received[1]).includes('>62<') && svgOf(received[1]).includes(MINT));
    const before = received.length;
    await new Promise((r) => setTimeout(r, 400));
    check('the same state is not sent again', received.length === before);
    step = 1;
    await until(() => received.length > before, 3000);
    check('a changed state is, in the colour that asks for attention', received[before] && svgOf(received[before]).includes(AMBER) && svgOf(received[before]).includes('needs you'));
    check('the picture with the API off says so', keyImage(null).includes('API off'));
    check('launch arguments are read as the application passes them',
      JSON.stringify(launchArguments(['-port', '28196', '-pluginUUID', 'ABC', '-registerEvent', 'registerPlugin', '-info', '{}']))
      === JSON.stringify({ port: '28196', pluginUUID: 'ABC', registerEvent: 'registerPlugin', info: '{}' }));
    plugin.close();
    app.close();
    api.close();
    console.log(failed ? 'self-test FAILED: ' + failed : 'self-test passed: registration, a key drawn, a change drawn, nothing sent twice');
    process.exit(failed ? 1 : 0);
  }));
}

if (require.main === module) {
  if (process.argv.includes('--self-test')) {
    selfTest();
  } else {
    const given = launchArguments(process.argv.slice(2));
    if (!given.port || !given.pluginUUID || !given.registerEvent) {
      console.error('This is a Stream Deck plugin: the Stream Deck application starts it. To try it by itself: node plugin.js --self-test');
      process.exit(64);
    }
    start({ port: given.port, pluginUUID: given.pluginUUID, registerEvent: given.registerEvent, api: null, interval: 2000 });
  }
}

module.exports = { keyImage, launchArguments };
