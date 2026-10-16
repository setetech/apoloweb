// node gravar.js <url> <pasta-quadros> [fps]
// env DURS='[ms,...]' troca a duração das cenas (montar.js usa a duração das falas); SO_CENA=n regrava uma cena.
// Edge headless + CDP: para cada cena, pausa todas as animações e avança o
// tempo quadro a quadro (currentTime), fotografando cada quadro. Determinístico.
const { spawn, spawnSync } = require('child_process');
const fs = require('fs'); const path = require('path'); const http = require('http');
const [url, saida, fpsArg] = process.argv.slice(2);
const FPS = Number(fpsArg) || 30;
fs.mkdirSync(saida, { recursive: true });
const EDGE = 'C:/Program Files (x86)/Microsoft/Edge/Application/msedge.exe';
const porta = 9335;
const edge = spawn(EDGE, ['--headless=new', '--disable-gpu', '--hide-scrollbars', '--disable-background-timer-throttling',
  '--disable-renderer-backgrounding', '--disable-backgrounding-occluded-windows', '--remote-debugging-port=' + porta,
  '--user-data-dir=' + path.join(saida, '..', 'perfil-video'), '--window-size=1920,1080', 'about:blank'], { stdio: 'ignore' });
const espera = (ms) => new Promise(r => setTimeout(r, ms));
const json = (u) => new Promise((res, rej) => http.get(u, r => { let d = ''; r.on('data', c => d += c); r.on('end', () => res(JSON.parse(d))); }).on('error', rej));
// O PID do spawn é só o lançador: o navegador real nasce dele e fica órfão (kill e taskkill /T não o alcançam,
// e os msedge vivos prendem o perfil-video). Fecha pelo próprio navegador (CDP Browser.close).
const fechar = async () => {
  try { const v = await json('http://127.0.0.1:' + porta + '/json/version'); const b = new WebSocket(v.webSocketDebuggerUrl);
    await new Promise((ok, erro) => { b.addEventListener('open', ok); b.addEventListener('error', erro); });
    b.send(JSON.stringify({ id: 1, method: 'Browser.close' })); await espera(1500); } catch (e) { }
  try { spawnSync('taskkill', ['/PID', String(edge.pid), '/T', '/F'], { stdio: 'ignore' }); } catch (e) { }
};
(async () => {
  let alvos;
  for (let i = 0; i < 120; i++) { try { alvos = await json('http://127.0.0.1:' + porta + '/json'); break; } catch (e) { await espera(250); } }
  if (!alvos) throw new Error('O Edge headless não abriu a porta ' + porta + ' (perfil-video preso? encerre os msedge com "perfil-video" na linha de comando).');
  const pg = alvos.find(t => t.type === 'page');
  const ws = new WebSocket(pg.webSocketDebuggerUrl);
  await new Promise(r => ws.addEventListener('open', r));
  let id = 0; const pend = new Map();
  ws.addEventListener('message', ev => { const m = JSON.parse(ev.data); if (m.id && pend.has(m.id)) { pend.get(m.id)(m); pend.delete(m.id); } });
  const cdp = (method, params) => new Promise((r, rej) => { const i = ++id; pend.set(i, r); ws.send(JSON.stringify({ id: i, method, params: params || {} }));
    setTimeout(() => { if (pend.has(i)) { pend.delete(i); rej(new Error('CDP sem resposta: ' + method)); } }, 20000); });
  const tenta = async (fn) => { for (let k = 1; ; k++) { try { return await fn(); } catch (e) { if (k >= 3) throw e; console.log('  ' + e.message + ' — tentando de novo'); } } };
  const ev = async (expr) => { const r = await cdp('Runtime.evaluate', { expression: expr, awaitPromise: true, returnByValue: true });
    if (r.result && r.result.exceptionDetails) throw new Error(JSON.stringify(r.result.exceptionDetails).slice(0, 300)); return r.result.result.value; };
  await cdp('Emulation.setDeviceMetricsOverride', { width: 1920, height: 1080, deviceScaleFactor: 1, mobile: false });
  await cdp('Page.enable'); await cdp('Runtime.enable');
  await cdp('Page.navigate', { url });
  await espera(3000);
  await ev('document.fonts.ready.then(()=>true)');
  const durs = process.env.DURS ? JSON.parse(process.env.DURS) : await ev('window.__durs');
  const card = await ev("(()=>{const e=document.getElementById('avatarCard');if(!e||!e.offsetParent)return null;const r=e.getBoundingClientRect();return {x:r.x,y:r.y,w:r.width,h:r.height};})()");
  fs.writeFileSync(saida.replace(/[\\/]+$/, '') + '.layout.json', JSON.stringify({ durs, card }));
  const total = durs.reduce((a, b) => a + b, 0);
  let quadro = 0, antes = 0;
  const SO = process.env.SO_CENA ? Number(process.env.SO_CENA) : -1;   // regrava só uma cena (0 = primeira)
  for (let c = 0; c < durs.length; c++) {
    const n = Math.round(durs[c] / 1000 * FPS);
    if (SO >= 0 && c !== SO) { quadro += n; antes += durs[c]; continue; }
    await ev(`window.__ir(${c}); true`);
    for (let f = 0; f < n; f++) {
      const t = f * 1000 / FPS;
      await tenta(() => ev(`document.getAnimations().forEach(a=>{a.pause(); a.currentTime=${t};});
        document.getElementById('vbar').style.width=(${(antes + t) / total * 100})+'%'; true`));
      const r = await tenta(() => cdp('Page.captureScreenshot', { format: 'jpeg', quality: 92 }));
      fs.writeFileSync(path.join(saida, 'q' + String(quadro++).padStart(5, '0') + '.jpg'), Buffer.from(r.result.data, 'base64'));
    }
    antes += durs[c];
    console.log('cena', c + 1, 'ok,', quadro, 'quadros');
  }
  ws.close(); await fechar(); process.exit(0);
})().catch(async e => { console.error(e); await fechar(); process.exit(1); });
