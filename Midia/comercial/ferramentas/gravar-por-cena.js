// Grava as cenas UMA POR VEZ, cada uma num Edge headless novo (gravar.js com SO_CENA), repetindo a cena que
// falhar (até 4 tentativas). Motivo: numa sessão longa o Page.captureScreenshot do headless às vezes para de
// responder (na ROT4058 travou 3 vezes seguidas na cena 2, em quadros diferentes). O montar-voz.js já grava assim;
// rode este à mão só para regravar os quadros e depois montar com montar-voz.js --sem-gravar.
//
//   node gravar-por-cena.js [pasta-quadros] [fps] [--tema claro] [--cenas 2,5]
//   Lê as durações do <pasta-quadros>.layout.json (que o gravar.js deixa); --cenas regrava só essas (1 = primeira).
const { spawnSync } = require('child_process');
const fs = require('fs'); const path = require('path');
const AQUI = __dirname;

// Grava as cenas de `cenas` (índices 0..n-1; padrão: todas) em `quadros`, com as durações `durs` (ms).
// Devolve true se todas gravaram.
function gravarPorCena(url, quadros, durs, fps, cenas, tentativas = 4) {
  const lista = cenas || durs.map((_, i) => i);
  for (const c of lista) {
    let ok = false;
    for (let k = 1; k <= tentativas && !ok; k++) {
      const r = spawnSync(process.execPath, [path.join(AQUI, 'gravar.js'), url, quadros, String(fps)],
        { stdio: 'inherit', env: { ...process.env, DURS: JSON.stringify(durs), SO_CENA: String(c) } });
      ok = r.status === 0;
      if (!ok) console.log('cena ' + (c + 1) + ': falhou na tentativa ' + k + (k < tentativas ? ', abrindo outro Edge' : ''));
    }
    if (!ok) { console.error('cena ' + (c + 1) + ' não gravou depois de ' + tentativas + ' tentativas'); return false; }
  }
  return true;
}
module.exports = { gravarPorCena };

if (require.main === module) {
  const a = process.argv.slice(2), o = {}, pos = [];
  for (let i = 0; i < a.length; i++) if (a[i].startsWith('--')) o[a[i].slice(2)] = a[++i]; else pos.push(a[i]);
  const QUADROS = path.resolve(pos[0] || path.join(AQUI, 'trabalho', 'quadros-voz'));
  const FPS = Number(pos[1]) || 30;
  const { durs } = JSON.parse(fs.readFileSync(QUADROS + '.layout.json', 'utf8'));
  const url = 'file:///' + path.join(AQUI, 'video.html').replace(/\\/g, '/') + '?video=1' + (o.tema ? '&tema=' + o.tema : '');
  const cenas = o.cenas ? o.cenas.split(',').map(n => Number(n) - 1) : null;
  if (!gravarPorCena(url, QUADROS, durs, FPS, cenas)) process.exit(1);
  const total = durs.reduce((s, d) => s + Math.round(d / 1000 * FPS), 0);
  console.log('quadros:', fs.readdirSync(QUADROS).length, 'de', total);
}
