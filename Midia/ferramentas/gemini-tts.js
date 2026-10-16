// Narração de apresentação do Colosso com o Gemini TTS (só voz, um áudio por cena).
//
//   node gemini-tts.js amostras [--vozes Charon,Kore,Sulafat] [--cena 1]   → trabalho\voz\amostra-<voz>.wav
//   node gemini-tts.js gerar [--voz Kore] [--cenas 3,7] [--refazer]        → trabalho\voz\cena01.wav … cena11.wav
//
// Opções: --modelo (padrão gemini-3.8-flash-tts) · --tom "instrução" (padrão: nenhuma — confira com transcrever.js se usar).
// Texto: ..\roteiro.md (ou --roteiro arquivo), um "## Cena N — título" por cena. Cena já gerada é mantida (--refazer).
// A chave vem de GEMINI_API_KEY, do .env da ROT8106 (Embarcados\8106 - Telegram IA\server\.env) e, como reserva,
// da seção [gemini] de Fontes\Chaves de Api.txt — outra conta, outra cota. Nunca deste código.
// Quando uma chave bate o limite diário (429), o script passa para a próxima e segue de onde parou.
const fs = require('fs'); const path = require('path'); const { spawnSync } = require('child_process');

const AQUI = __dirname, SAIDA = path.join(AQUI, 'trabalho', 'voz');
const ENV_8106 = 'C:/Sete/Colosso/Fontes/Modulos/Embarcados/8106 - Telegram IA/server/.env';
const CHAVES_TXT = 'C:/Sete/Colosso/Fontes/Chaves de Api.txt';
const FFMPEG = 'C:/ffmpeg/bin/ffmpeg.exe';
const TOM = '-';   // sem instrução: o modelo lê a direção de tom em voz alta (pt e en), e recusa systemInstruction

const o = { _: [] }; { const a = process.argv.slice(2); for (let i = 0; i < a.length; i++) {
  if (a[i].startsWith('--')) o[a[i].slice(2)] = a[i + 1] && !a[i + 1].startsWith('--') ? a[++i] : true; else o._.push(a[i]); } }
const MODELO = o.modelo || 'gemini-3.8-flash-tts';
const ARQ_ROTEIRO = path.resolve(AQUI, o.roteiro || '../roteiro.md');

// Todas as chaves disponíveis, na ordem de uso. A cota do TTS é por conta (100 pedidos/dia por modelo),
// então a reserva do Chaves de Api.txt é o que salva um vídeo no meio da geração.
function chaves() {
  const lista = [], juntar = k => { k = String(k || '').trim(); if (k && !lista.includes(k)) lista.push(k); };
  juntar(process.env.GEMINI_API_KEY);
  if (fs.existsSync(ENV_8106)) {
    const m = /^\s*GEMINI_API_KEY\s*=\s*"?([^"\r\n]+)"?/m.exec(fs.readFileSync(ENV_8106, 'utf8'));
    if (m) juntar(m[1]);
  }
  if (fs.existsSync(CHAVES_TXT)) {
    const sec = /\[gemini\]([\s\S]*?)(\n\s*\[|$)/.exec(fs.readFileSync(CHAVES_TXT, 'utf8'));
    const m = sec && /^\s*apikey\s*=\s*"?([^"\r\n]+)"?/m.exec(sec[1]);
    if (m) juntar(m[1]);
  }
  if (!lista.length) throw new Error('Chave do Gemini não encontrada (GEMINI_API_KEY, ' + ENV_8106 + ' ou ' + CHAVES_TXT + ').');
  return lista;
}
const CHAVES = chaves();
let iChave = 0;   // avança quando a cota da chave atual estoura; não volta atrás nesta execução

function lerRoteiro() {
  return fs.readFileSync(ARQ_ROTEIRO, 'utf8').replace(/\r/g, '').split(/^## /m).slice(1)
    .map(b => { const [t, ...r] = b.split('\n'); const m = /^Cena\s+(\d+)\s*[—-]\s*(.*)$/.exec(t.trim());
      return m && { n: Number(m[1]), titulo: m[2].trim(), texto: r.join(' ').replace(/\s+/g, ' ').trim() }; })
    .filter(c => c && c.texto).sort((a, b) => a.n - b.n);
}

async function falar(texto, voz, arquivo) {
  const corpo = {
    // Instrução de tom em português é lida em voz alta, e o modelo recusa systemInstruction (conferido por transcrição);
    // a direção curta em inglês (formato da documentação do Google) não é lida. --tom - = sem instrução.
    contents: [{ parts: [{ text: (o.tom || TOM) === '-' ? texto : o.tom + '\n' + texto }] }],
    generationConfig: { responseModalities: ['AUDIO'], speechConfig: { voiceConfig: { prebuiltVoiceConfig: { voiceName: voz } } } }
  };
  for (let tent = 1; ; tent++) {
    const r = await fetch('https://generativelanguage.googleapis.com/v1beta/models/' + MODELO + ':generateContent',
      { method: 'POST', headers: { 'x-goog-api-key': CHAVES[iChave], 'Content-Type': 'application/json' }, body: JSON.stringify(corpo) });
    const j = await r.json().catch(() => ({}));
    const parte = j.candidates && j.candidates[0] && j.candidates[0].content && (j.candidates[0].content.parts || []).find(p => p.inlineData);
    if (r.ok && parte) {
      // O gemini-3.8 devolve audio/wav com um bloco C2PA (assinatura de procedência) depois dos dados: lido como
      // PCM cru, o cabeçalho vira estalo e o C2PA vira 0,13 s de ruído no talo. WAV vai direto para o ffmpeg.
      // Modelos 2.5 devolvem audio/L16 (PCM cru, rate=24000 no mimeType).
      const mime = parte.inlineData.mimeType || '';
      const dados = Buffer.from(parte.inlineData.data, 'base64');
      const ehWav = /wav/i.test(mime) || dados.toString('latin1', 0, 4) === 'RIFF';
      const taxa = Number((/rate=(\d+)/.exec(mime) || [])[1] || 24000);
      const pcm = path.join(SAIDA, ehWav ? '_tmp.wav' : '_tmp.pcm');
      fs.writeFileSync(pcm, dados);
      const f = spawnSync(FFMPEG, ['-y', '-loglevel', 'error', ...(ehWav ? [] : ['-f', 's16le', '-ar', String(taxa), '-ac', '1']), '-i', pcm,
        '-af', 'silenceremove=start_periods=1:start_threshold=-50dB,areverse,silenceremove=start_periods=1:start_threshold=-50dB,areverse',
        arquivo], { stdio: 'inherit' });
      fs.unlinkSync(pcm);
      if (f.status !== 0) throw new Error('ffmpeg falhou ao converter ' + arquivo);
      const uso = j.usageMetadata || {};
      return { seg: duracao(arquivo), tokens: (uso.promptTokenCount || 0) + '+' + (uso.candidatesTokenCount || 0) };
    }
    const msg = (j.error && (j.error.code + ' ' + j.error.message)) || ('HTTP ' + r.status + ' sem áudio na resposta');
    if (r.status === 429 && iChave < CHAVES.length - 1) {   // cota desta conta estourou: vai para a próxima chave
      iChave++; tent--;                                      // virar de chave não gasta tentativa
      console.log('  cota estourada — passando para a chave ' + (iChave + 1) + ' de ' + CHAVES.length);
      continue;
    }
    if (tent >= 3 || (r.status >= 400 && r.status < 500 && r.status !== 429)) throw new Error(msg);
    console.log('  ' + msg.slice(0, 120) + ' — tentando de novo');
    await new Promise(res => setTimeout(res, 4000 * tent));
  }
}

function duracao(arq) {
  const r = spawnSync(FFMPEG, ['-hide_banner', '-i', arq, '-f', 'null', '-'], { encoding: 'utf8' });
  const m = /Duration:\s*(\d+):(\d+):([\d.]+)/.exec(r.stderr || ''); return m ? m[1] * 3600 + m[2] * 60 + Number(m[3]) : 0;
}

(async () => {
  fs.mkdirSync(SAIDA, { recursive: true });
  const cenas = lerRoteiro();
  const cmd = o._[0];
  if (cmd === 'amostras') {
    const c = cenas.find(x => x.n === Number(o.cena || 1));
    for (const voz of String(o.vozes || 'Charon,Kore,Sulafat').split(',').map(s => s.trim()).filter(Boolean)) {
      const arq = path.join(SAIDA, 'amostra-' + voz + '.wav');
      const r = await falar(c.texto, voz, arq);
      console.log(voz.padEnd(12) + r.seg.toFixed(1) + ' s  (tokens ' + r.tokens + ')  ' + arq);
    }
  } else if (cmd === 'gerar') {
    o.voz = o.voz || 'Kore';   // voz aprovada pelo usuário em 2026-10-12
    const quais = o.cenas ? String(o.cenas).split(',').map(Number) : null;
    for (const c of cenas) {
      if (quais && !quais.includes(c.n)) continue;
      const arq = path.join(SAIDA, 'cena' + String(c.n).padStart(2, '0') + '.wav');
      if (fs.existsSync(arq) && !o.refazer && !quais) { console.log('cena ' + c.n + ': já existe (' + duracao(arq).toFixed(1) + ' s)'); continue; }
      const r = await falar(c.texto, o.voz, arq);
      console.log('cena ' + String(c.n).padStart(2) + ': ' + r.seg.toFixed(1) + ' s  (tokens ' + r.tokens + ')');
    }
    fs.writeFileSync(path.join(SAIDA, 'voz.json'), JSON.stringify({ voz: o.voz, modelo: MODELO, tom: o.tom || TOM, em: new Date().toISOString() }, null, 2));
  } else console.log(fs.readFileSync(__filename, 'utf8').split('\n').slice(0, 8).join('\n'));
})().catch(e => { console.error('ERRO: ' + e.message); process.exit(1); });
