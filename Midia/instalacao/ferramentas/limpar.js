// Apaga os temporários de trabalho\ depois que o vídeo está pronto (o montar-voz.js chama sozinho no fim).
//
//   node limpar.js              apaga quadros, perfil do Edge, folha de contato, quadros soltos e logs
//   node limpar.js --simular    só lista o que seria apagado e quanto libera
//   node limpar.js --tudo       também apaga trabalho\voz (aí trocar uma fala exige gerar a narração de novo)
//
// Lista FECHADA do que é temporário (tudo se refaz rodando de novo conferir.js / montar-voz.js). Fica:
// trabalho\voz (cena*.wav — trocar uma fala = gerar --cenas N + montar-voz.js) e qualquer outra coisa que
// não esteja na lista (ex.: .mp4 de avatar, que custou cota de API).
const fs = require('fs'); const path = require('path'); const { spawnSync } = require('child_process');

const TEMPORARIO = [
  { re: /^quadros(-[\w-]+)?$/, dir: true },          // quadros-voz, quadros-conferencia, quadros-avatar (~0,5–0,8 GB cada)
  { re: /^quadros(-[\w-]+)?\.layout\.json$/ },
  { re: /^perfil-video$/, dir: true },               // perfil do Edge headless (~0,5 GB)
  { re: /\.(jpe?g|png)$/i },                         // folha de contato e quadros extraídos para conferir
  { re: /\.log$/i },
];

function tamanho(p) {
  let st; try { st = fs.lstatSync(p); } catch { return 0; }
  if (!st.isDirectory()) return st.size;
  let t = 0; for (const f of fs.readdirSync(p)) t += tamanho(path.join(p, f)); return t;
}
const mb = n => (n / 1048576).toFixed(n < 10485760 ? 1 : 0) + ' MB';

// Apaga arquivo ou pasta. NÃO use fs.rmSync: no Node 24 (Windows) ele não apaga nada e não dá erro quando o
// caminho tem acento ("3003 - Preços de Concorrentes"). unlinkSync/rmdirSync funcionam. Confere no fim.
function apagar(p, tentativas = 5) {
  for (let i = 1; ; i++) {
    try {
      const st = fs.lstatSync(p);
      if (st.isDirectory()) {
        for (const f of fs.readdirSync(p)) apagar(path.join(p, f), 1);
        fs.rmdirSync(p);
      } else {
        try { fs.unlinkSync(p); } catch (e) { if (e.code !== 'EPERM') throw e; fs.chmodSync(p, 0o666); fs.unlinkSync(p); }
      }
    } catch (e) {
      if (e.code === 'ENOENT') return;
      if (i >= tentativas) throw e;
      spawnSync(process.execPath, ['-e', 'setTimeout(()=>{},400)']);   // espera o Edge soltar o arquivo
      continue;
    }
    if (!fs.existsSync(p)) return;
    if (i >= tentativas) { const e = new Error('continua existindo: ' + p); e.code = 'NAOAPAGOU'; throw e; }
  }
}

// msedge da gravação que ficou vivo prende o perfil-video: encerra só os que usam ESTE perfil.
function soltarPerfil(perfil) {
  if (process.platform !== 'win32' || !fs.existsSync(perfil)) return;
  const alvo = perfil.replace(/'/g, "''");
  spawnSync('powershell.exe', ['-NoProfile', '-Command',
    `Get-CimInstance Win32_Process -Filter "Name='msedge.exe'" | Where-Object { $_.CommandLine -like '*${alvo}*' } | ` +
    'ForEach-Object { try { Stop-Process -Id $_.ProcessId -Force -ErrorAction Stop } catch {} }'], { stdio: 'ignore' });
}

function limpar(trab, op = {}) {
  if (!fs.existsSync(trab)) return { apagados: [], liberado: 0, falhas: [] };
  const regras = op.tudo ? [...TEMPORARIO, { re: /^voz$/, dir: true }] : TEMPORARIO;
  const apagados = [], falhas = [];
  let liberado = 0;
  for (const nome of fs.readdirSync(trab)) {
    const p = path.join(trab, nome);
    const ehDir = fs.lstatSync(p).isDirectory();
    if (!regras.some(r => r.re.test(nome) && !!r.dir === ehDir)) continue;
    const t = tamanho(p);
    if (op.simular) { apagados.push(nome); liberado += t; continue; }
    if (nome === 'perfil-video') soltarPerfil(p);
    try {
      apagar(p);
      apagados.push(nome); liberado += t;
    } catch (e) { falhas.push(nome + ' (' + e.code + ')'); }
  }
  return { apagados, liberado, falhas };
}

function relatar(trab, r, simular) {
  if (!r.apagados.length && !r.falhas.length) { console.log('Limpeza: nada temporário em ' + trab); return; }
  console.log((simular ? 'Limpeza (simulação) liberaria ' : 'Limpeza: liberados ') + mb(r.liberado) + ' — ' + r.apagados.join(', '));
  if (r.falhas.length) console.log('  não apagados (em uso?): ' + r.falhas.join(', ') + ' — rode "node limpar.js" de novo depois.');
  const resta = (fs.existsSync(trab) ? fs.readdirSync(trab) : []).filter(n => !r.apagados.includes(n));
  if (resta.length) console.log('  mantidos: ' + resta.join(', '));
}

module.exports = { limpar, relatar, apagar };

if (require.main === module) {
  const a = process.argv.slice(2);
  const trab = path.join(__dirname, 'trabalho');
  const op = { simular: a.includes('--simular'), tudo: a.includes('--tudo') };
  relatar(trab, limpar(trab, op), op.simular);
}
