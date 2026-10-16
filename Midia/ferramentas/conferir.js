// node conferir.js [--avatar] [--tema claro]  → trabalho\conferencia.jpg
// Grava a animação a 1 quadro/s (~20 s) e monta uma folha de contato com o ÚLTIMO quadro de cada cena (tudo já
// apareceu). É onde se pega texto cortado ou saindo da caixa — SVG não quebra linha sozinho. Rode antes do vídeo.
const fs = require('fs'); const path = require('path'); const { spawnSync } = require('child_process');
const AQUI = __dirname, TRAB = path.join(AQUI, 'trabalho'), Q = path.join(TRAB, 'quadros-conferencia');
const HTML = path.join(AQUI, 'video.html'), FFMPEG = 'C:/ffmpeg/bin/ffmpeg.exe';

const durs = [...fs.readFileSync(HTML, 'utf8').matchAll(/<svg class="cena[^"]*"[^>]*data-dur="(\d+)"/g)].map(m => Number(m[1]));
require('./limpar.js').apagar(Q);   // fs.rmSync não apaga caminho com acento no Node 24
const iTema = process.argv.indexOf('--tema');   // tema do Colosso; sem ele a gravação sai no escuro
const url = 'file:///' + HTML.replace(/\\/g, '/') + (process.argv.includes('--avatar') ? '?avatar=1' : '?video=1') +
  (iTema > 0 && process.argv[iTema + 1] ? '&tema=' + process.argv[iTema + 1] : '');
const r = spawnSync(process.execPath, [path.join(AQUI, 'gravar.js'), url, Q, '1'], { stdio: ['ignore', 'ignore', 'inherit'] });
if (r.status !== 0) throw new Error('gravar.js falhou');

let acum = 0; const ultimos = durs.map(ms => { acum += Math.round(ms / 1000); return acum - 1; });
const lado = Math.ceil(Math.sqrt(durs.length)), linhas = Math.ceil(durs.length / lado);
const sel = ultimos.map(n => 'eq(n\\,' + n + ')').join('+');
const saida = path.join(TRAB, 'conferencia.jpg');
const f = spawnSync(FFMPEG, ['-y', '-loglevel', 'error', '-i', path.join(Q, 'q%05d.jpg'),
  '-vf', "select='" + sel + "',scale=960:-1,tile=" + lado + 'x' + linhas + ':padding=8:color=white', '-frames:v', '1', '-q:v', '3', saida], { stdio: 'inherit' });
if (f.status !== 0) throw new Error('ffmpeg falhou');
console.log(durs.length + ' cenas · quadros finais ' + ultimos.join(',') + '\nFolha de contato: ' + saida +
  '\nQuadro final de uma cena em tamanho real: ' + path.join(Q, 'q' + String(ultimos[0]).padStart(5, '0') + '.jpg') + ' (troque o número)');
