// Junta a animação com a narração (um áudio por cena, do gemini-tts.js) — ou gera o vídeo sem voz (--mudo).
//
//   node montar-voz.js [--saida ..\inteligencia-de-vendas-narrado.mp4] [--sem-gravar] [--respiro 0.5] [--folga 0.8] [--tema claro] [--manter]
//   No fim apaga os temporários de trabalho\ (limpar.js), menos a narração; --manter não apaga nada.
//   --tema: um dos temas do Colosso (escuro, claro, floresta, oceano, natal...); sem ele o vídeo sai no escuro.
//
// Cada cena dura: respiro + fala + folga (nunca menos que a animação original). Layout original, sem avatar.
// Áudio normalizado para -16 LUFS (padrão de vídeo para web/celular).
const fs = require('fs'); const path = require('path'); const { spawnSync } = require('child_process');

const AQUI = __dirname, TRAB = path.join(AQUI, 'trabalho'), VOZ = path.join(TRAB, 'voz');
const FFMPEG = 'C:/ffmpeg/bin/ffmpeg.exe', FPS = 30;
const o = {}; { const a = process.argv.slice(2); for (let i = 0; i < a.length; i++) if (a[i].startsWith('--')) o[a[i].slice(2)] = a[i + 1] && !a[i + 1].startsWith('--') ? a[++i] : true; }
const SAIDA = path.resolve(AQUI, o.saida || '../apresentacao.mp4');
const MUDO = !!o.mudo;
const QUADROS = path.join(TRAB, 'quadros-voz');
const HTML = path.join(AQUI, 'video.html');
const RESPIRO = Number(o.respiro || 0.5), FOLGA = Number(o.folga || 0.8);

function duracao(arq) {
  const r = spawnSync(FFMPEG, ['-hide_banner', '-i', arq, '-f', 'null', '-'], { encoding: 'utf8' });
  const m = /Duration:\s*(\d+):(\d+):([\d.]+)/.exec(r.stderr || ''); return m ? m[1] * 3600 + m[2] * 60 + Number(m[3]) : 0;
}
const seg = (s) => s.toFixed(3);

const animMs = [...fs.readFileSync(HTML, 'utf8').matchAll(/<svg class="cena[^"]*"[^>]*data-dur="(\d+)"/g)].map(m => Number(m[1]));
const cenas = animMs.map((ms, i) => {
  const wav = path.join(VOZ, 'cena' + String(i + 1).padStart(2, '0') + '.wav');
  if (MUDO) return { cena: i + 1, wav: null, fala: 0, quadros: Math.round(ms / 1000 * FPS) };
  if (!fs.existsSync(wav)) throw new Error('Falta ' + wav + ' (rode: node gemini-tts.js gerar --voz ...)');
  const fala = duracao(wav);
  const quadros = Math.max(Math.round((RESPIRO + fala + FOLGA) * FPS), Math.round(ms / 1000 * FPS));
  return { cena: i + 1, wav, fala, quadros };
});
const TOTAL = cenas.reduce((s, c) => s + c.quadros, 0) / FPS;
if (!MUDO) for (const c of cenas) console.log('  cena ' + String(c.cena).padStart(2) + '  fala ' + c.fala.toFixed(1) + ' s → cena ' + (c.quadros / FPS).toFixed(1) + ' s');

if (!o['sem-gravar']) {
  require('./limpar.js').apagar(QUADROS);   // fs.rmSync não apaga caminho com acento no Node 24
  const url = 'file:///' + HTML.replace(/\\/g, '/') + '?video=1' +   // layout de gravação 1920×1080
    (o.tema && o.tema !== true ? '&tema=' + o.tema : '');             // tema do Colosso (padrão: escuro)
  const r = spawnSync(process.execPath, [path.join(AQUI, 'gravar.js'), url, QUADROS, String(FPS)],
    { stdio: 'inherit', env: { ...process.env, DURS: JSON.stringify(cenas.map(c => c.quadros * 1000 / FPS)) } });
  if (r.status !== 0) throw new Error('gravar.js falhou');
}

const args = ['-y', '-hide_banner', '-loglevel', 'error', '-framerate', String(FPS), '-i', path.join(QUADROS, 'q%05d.jpg')];
if (!MUDO) cenas.forEach(c => args.push('-i', c.wav));
const g = MUDO ? [] : cenas.map((c, i) => '[' + (i + 1) + ':a]aresample=48000,aformat=channel_layouts=stereo,adelay=' + Math.round(RESPIRO * 1000) +
  ':all=1,apad,atrim=0:' + seg(c.quadros / FPS) + ',asetpts=PTS-STARTPTS[a' + i + ']');
if (!MUDO) g.push(cenas.map((c, i) => '[a' + i + ']').join('') + 'concat=n=' + cenas.length + ':v=0:a=1,loudnorm=I=-16:TP=-1.5:LRA=11,aresample=48000,alimiter=limit=0.8:level=false,' +
  'afade=t=out:st=' + seg(TOTAL - 0.7) + ':d=0.7[a]');
g.push('[0:v]fade=t=in:st=0:d=0.6,fade=t=out:st=' + seg(TOTAL - 0.7) + ':d=0.7,scale=in_range=pc:out_range=tv,format=yuv420p[v]');
args.push('-filter_complex', g.join(';'), '-map', '[v]', ...(MUDO ? [] : ['-map', '[a]', '-c:a', 'aac', '-b:a', '160k']), '-t', seg(TOTAL),
  '-c:v', 'libx264', '-preset', 'slow', '-crf', '20', '-r', String(FPS), '-movflags', '+faststart', SAIDA);
console.log('Montando ' + TOTAL.toFixed(1) + ' s → ' + SAIDA);
const r = spawnSync(FFMPEG, args, { stdio: 'inherit' });
if (r.status !== 0) throw new Error('ffmpeg falhou');
console.log('Pronto: ' + SAIDA + ' (' + (fs.statSync(SAIDA).size / 1048576).toFixed(1) + ' MB)');

// Vídeo pronto: apaga os temporários (quadros, perfil do Edge, folha de contato...). A narração (trabalho\voz)
// fica, para trocar uma fala depois. --manter guarda tudo (ex.: para remontar com --sem-gravar).
if (!o.manter) { const { limpar, relatar } = require('./limpar.js'); relatar(TRAB, limpar(TRAB)); }
