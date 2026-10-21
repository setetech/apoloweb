// node transcrever.js arquivo.wav [...]  — confere com o Gemini o que foi realmente falado num áudio
// (pega a instrução de tom lida em voz alta, palavra pulada, sigla soletrada errado). Chave: a mesma do gemini-tts.js.
const fs = require('fs');
const ENV_8106 = 'C:/Sete/Colosso/Fontes/Modulos/Embarcados/8106 - Telegram IA/server/.env';
const CHAVES_TXT = 'C:/Sete/Colosso/Fontes/Chaves de Api.txt';

function chaves() {   // mesma ordem do gemini-tts.js; a última é a reserva de outra conta (outra cota)
  const lista = [], juntar = k => { k = String(k || '').trim(); if (k && !lista.includes(k)) lista.push(k); };
  juntar(process.env.GEMINI_API_KEY);
  if (fs.existsSync(ENV_8106)) juntar((/^\s*GEMINI_API_KEY\s*=\s*"?([^"\r\n]+)"?/m.exec(fs.readFileSync(ENV_8106, 'utf8')) || [])[1]);
  if (fs.existsSync(CHAVES_TXT)) {
    const sec = /\[gemini\]([\s\S]*?)(\n\s*\[|$)/.exec(fs.readFileSync(CHAVES_TXT, 'utf8'));
    if (sec) juntar((/^\s*apikey\s*=\s*"?([^"\r\n]+)"?/m.exec(sec[1]) || [])[1]);
  }
  if (!lista.length) throw new Error('Chave do Gemini não encontrada.');
  return lista;
}
const CHAVES = chaves();
let iChave = 0;

(async () => {
  for (const arq of process.argv.slice(2)) {
    let j;
    for (;;) {
      const r = await fetch('https://generativelanguage.googleapis.com/v1beta/models/gemini-3.8-flash:generateContent', {
        method: 'POST', headers: { 'x-goog-api-key': CHAVES[iChave], 'Content-Type': 'application/json' },
        body: JSON.stringify({ contents: [{ parts: [{ inlineData: { mimeType: 'audio/wav', data: fs.readFileSync(arq).toString('base64') } },
          { text: 'Transcreva exatamente o que é falado neste áudio, palavra por palavra, em qualquer idioma. Só a transcrição.' }] }] })
      });
      j = await r.json();
      if (r.status === 429 && iChave < CHAVES.length - 1) { iChave++; console.log('  cota estourada — chave ' + (iChave + 1) + ' de ' + CHAVES.length); continue; }
      break;
    }
    console.log('== ' + arq + '\n' + (j.error ? 'ERRO ' + j.error.message : j.candidates[0].content.parts.map(p => p.text).join('').trim()));
  }
})().catch(e => { console.error('ERRO: ' + e.message); process.exit(1); });
