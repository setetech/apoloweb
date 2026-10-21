// Publica o vídeo narrado na Central de Ajuda do Atenas (material VIDEO da rotina) e o encaixa na
// trilha de treinamento: completa a aula que já tem o manual da rotina ou, se ela ainda não está em
// trilha nenhuma, inclui a aula no fim da trilha com mais aulas do mesmo módulo.
//
//   node publicar-atenas.js                          rotina, módulo e vídeo deduzidos da pasta
//   node publicar-atenas.js --video ..\X-narrado.mp4 --rotina 6001 --modulo Financeiro --titulo "..."
//   --equipe       vídeo só para a equipe (padrão: a mesma visibilidade do manual da rotina; sem manual, visível)
//   --sem-trilha   só publica o vídeo
//
// Acesso: a mesma chave de integração da skill colosso-ajuda-rag, em %USERPROFILE%\.colosso\atenas.ini
// ([atenas] url= e chave=) ou ATENAS_URL / ATENAS_CHAVE. Nunca imprime a chave.
// O servidor só ENCAIXA na trilha (inclui no fim ou completa o vídeo que falta): não apaga, não troca
// o vídeo de uma aula que já tem outro e não reordena -- a curadoria é da tela Configurar treinamento.
const fs = require('fs');
const path = require('path');

const args = process.argv.slice(2);
const opt = n => { const i = args.indexOf(n); return i >= 0 ? args[i + 1] : undefined; };
const DIR = __dirname;                                  // <módulo>\Midia\ferramentas
const MIDIA = path.dirname(DIR);
const PASTA_ROTINA = path.dirname(MIDIA);
const PARTE = 3 * 1024 * 1024;                          // o servidor aceita até 4 MB por parte

function lerConfig() {
  const arq = path.join(process.env.USERPROFILE || process.env.HOME || '.', '.colosso', 'atenas.ini');
  const cfg = { url: '', chave: '' };
  if (fs.existsSync(arq))
    for (const l of fs.readFileSync(arq, 'utf8').replace(/^﻿/, '').split(/\r?\n/)) {
      const m = l.match(/^\s*(url|chave)\s*=\s*(.*?)\s*$/i);
      if (m) cfg[m[1].toLowerCase()] = m[2];
    }
  cfg.url = (process.env.ATENAS_URL || cfg.url).replace(/\/+$/, '');
  cfg.chave = process.env.ATENAS_CHAVE || cfg.chave;
  if (!cfg.url || !cfg.chave) {
    console.log(`Atenas não configurado: grave url= e chave= em ${arq} (a chave é gerada em Ajustes › Chaves de integração).`);
    process.exit(1);
  }
  return cfg;
}

function chamador(cfg) {
  return async (metodo, rota, corpo) => {
    let r;
    try {
      r = await fetch(cfg.url + rota, {
        method: metodo,
        headers: Object.assign({ Authorization: 'Bearer ' + cfg.chave }, corpo ? { 'Content-Type': 'application/json' } : {}),
        body: corpo ? JSON.stringify(corpo) : undefined,
      });
    } catch (e) {
      throw Object.assign(new Error(`Atenas fora do ar em ${cfg.url}`), { status: 0 });
    }
    let d = null;
    try { d = await r.json(); } catch { /* sem corpo JSON */ }
    if (!r.ok) throw Object.assign(new Error(r.status === 401
      ? 'chave de integração inválida ou revogada'
      : (d && d.erro) || `HTTP ${r.status}`), { status: r.status });
    return d;
  };
}

const semAcento = s => String(s || '').normalize('NFD').replace(/\p{M}/gu, '').toLowerCase().trim();

// Dados do vídeo a partir da pasta: <Modulos>\<Módulo>\<nnnn - Nome>\Midia\ferramentas
function deduzir() {
  const nomePasta = path.basename(PASTA_ROTINA);
  const rotina = opt('--rotina') || (nomePasta.match(/^\s*(\d{3,5})/) || [])[1] || '';
  const modulo = opt('--modulo') || path.basename(path.dirname(PASTA_ROTINA));
  let video = opt('--video');
  if (!video) {
    const mp4 = fs.readdirSync(MIDIA).filter(f => /-narrado\.mp4$/i.test(f));
    if (mp4.length !== 1) {
      console.log(mp4.length ? `Mais de um vídeo narrado em ${MIDIA}: use --video.` : `Nenhum *-narrado.mp4 em ${MIDIA}: monte o vídeo antes.`);
      process.exit(1);
    }
    video = path.join(MIDIA, mp4[0]);
  }
  video = path.resolve(DIR, video);
  let titulo = opt('--titulo'), descricao = '';
  const html = path.join(DIR, 'video.html');
  if (fs.existsSync(html)) {
    const s = fs.readFileSync(html, 'utf8');
    const h1 = (s.match(/<h1>([^<]+)<\/h1>/) || [])[1];
    const lead = (s.match(/<p class="lead">([^<]+)<\/p>/) || [])[1];
    if (!titulo && h1 && !h1.includes('{{')) titulo = h1.trim();
    if (lead && !lead.includes('{{')) descricao = lead.trim();
  }
  titulo = (titulo || path.basename(video, '.mp4')) + ' (vídeo)';
  return { rotina, modulo, video, titulo, descricao: descricao || 'Apresentação narrada da rotina.' };
}

async function principal() {
  const cfg = lerConfig();
  const chamar = chamador(cfg);
  const d = deduzir();
  if (!fs.existsSync(d.video)) { console.log('Vídeo não encontrado: ' + d.video); process.exit(1); }
  if (!d.rotina) { console.log('Não achei o número da rotina pela pasta: use --rotina nnnn.'); process.exit(1); }
  const bytes = fs.readFileSync(d.video);
  const nomeArq = path.basename(d.video);

  // ---- 1. material VIDEO
  const todos = (await chamar('GET', '/api/ajuda')) || [];
  const manual = todos.filter(m => m.tipo === 'MD' && String(m.rotina || '') === d.rotina)
    .sort((a, b) => Number(b.versao) - Number(a.versao))[0];
  const visivel = args.includes('--equipe') ? 'N' : (manual ? manual.visivel_cliente : 'S');
  const atual = todos.filter(m => m.tipo === 'VIDEO' && String(m.rotina || '') === d.rotina)
    .sort((a, b) => (b.nome_arq === nomeArq) - (a.nome_arq === nomeArq))[0];
  let videoId, situacao;
  if (atual && atual.nome_arq === nomeArq && Number(atual.tamanho) === bytes.length && atual.titulo === d.titulo) {
    videoId = Number(atual.id); situacao = 'sem mudança';
  } else {
    const corpo = { tipo: 'VIDEO', rotina: d.rotina, modulo: d.modulo, titulo: d.titulo, url: '',
      descricao: (atual && atual.descricao) || d.descricao,
      visivel_cliente: atual ? atual.visivel_cliente : visivel };
    videoId = atual ? (await chamar('PUT', `/api/ajuda/${atual.id}`, corpo), Number(atual.id))
                    : Number((await chamar('POST', '/api/ajuda', corpo)).id);
    const partes = Math.max(1, Math.ceil(bytes.length / PARTE));
    let lote = 0;
    for (let i = 0; i < partes; i++) {
      const r = await chamar('POST', `/api/ajuda/${videoId}/arquivo`, {
        parte: i, lote, ultimo: i === partes - 1 ? 'S' : 'N', nome: nomeArq, mime: 'video/mp4',
        dados_b64: bytes.subarray(i * PARTE, (i + 1) * PARTE).toString('base64'),
      });
      lote = r.lote;
      process.stdout.write(`\r  enviando ${nomeArq}: ${Math.round((i + 1) / partes * 100)}%`);
    }
    process.stdout.write('\n');
    situacao = atual ? 'atualizado' : 'incluído';
  }
  console.log(`Atenas (${cfg.url}): vídeo ${videoId} "${d.titulo}" — ${situacao}` +
    ` (${(bytes.length / 1048576).toFixed(1)} MB, ${visivel === 'S' && !atual ? 'visível ao cliente' : atual ? 'visibilidade mantida' : 'só equipe'})`);

  if (args.includes('--sem-trilha')) return;

  // ---- 2. trilha de treinamento
  let tr;
  try { tr = await chamar('GET', '/api/trilhas-integracao'); }
  catch (e) {
    console.log(e.status === 404 || e.status === 403
      ? 'Trilhas: este Atenas ainda não tem o encaixe automático — atualize o Atenas.exe. O vídeo foi publicado.'
      : 'Trilhas: ' + e.message + '. O vídeo foi publicado.');
    return;
  }
  const itens = tr.itens || [];
  const nomeTrilha = id => ((tr.trilhas || []).find(t => Number(t.id) === Number(id)) || {}).titulo;
  const encaixar = corpo => chamar('POST', '/api/trilhas-integracao/encaixar', corpo);

  const comVideo = itens.filter(i => Number(i.video_id) === videoId);
  if (comVideo.length) {
    comVideo.forEach(i => console.log(`Trilhas: o vídeo já está na aula "${i.titulo}" de "${nomeTrilha(i.trilha_id)}".`));
    return;
  }
  const doManual = manual ? itens.filter(i => Number(i.ajuda_id) === Number(manual.id)) : [];
  if (doManual.length) {
    for (const i of doManual) {
      const r = await encaixar({ trilha_id: Number(i.trilha_id), ajuda_id: Number(manual.id), video_id: videoId });
      console.log(r.acao === 'video'
        ? `Trilhas: ✔ vídeo posto na aula "${i.titulo}" de "${nomeTrilha(i.trilha_id)}" (que já tinha o manual).`
        : `Trilhas: a aula "${i.titulo}" de "${nomeTrilha(i.trilha_id)}" já tem outro vídeo (${i.video_id}); ` +
          'troque pela tela Configurar treinamento se este for o certo.');
    }
    return;
  }
  // ainda não está em trilha: a ativa com mais aulas do mesmo módulo (desempate: mesmo milhar)
  const porId = new Map(todos.map(m => [Number(m.id), m]));
  const mod = semAcento(d.modulo);
  const paraCliente = visivel === 'S' || (atual && atual.visivel_cliente === 'S');
  let melhor = null;
  for (const t of (tr.trilhas || []).filter(x => x.ativo === 'S' && !(paraCliente && x.publico === 'EQUIPE'))) {
    let pontos = 0, milhar = 0;
    for (const i of itens.filter(x => Number(x.trilha_id) === Number(t.id))) {
      const m = porId.get(Number(i.ajuda_id)) || porId.get(Number(i.video_id));
      if (!m) continue;
      if (mod && semAcento(m.modulo) === mod) pontos++;
      const r = String(m.rotina || '');
      if (r.length === d.rotina.length && r[0] === d.rotina[0]) milhar++;
    }
    if (pontos > 0 && (!melhor || pontos > melhor.pontos || (pontos === melhor.pontos && milhar > melhor.milhar)))
      melhor = { t, pontos, milhar };
  }
  if (!melhor) {
    console.log(`Trilhas: ⚠ nenhuma trilha ativa tem aulas do módulo "${d.modulo}" — encaixe pela tela Configurar treinamento.`);
    return;
  }
  const r = await encaixar({
    trilha_id: Number(melhor.t.id), ajuda_id: manual ? Number(manual.id) : 0, video_id: videoId,
    titulo: d.titulo.replace(/ \(vídeo\)$/, ''), observacao: d.descricao,
  });
  console.log(`Trilhas: ✔ aula "${d.titulo.replace(/ \(vídeo\)$/, '')}" ${r.acao === 'incluida' ? 'incluída no fim de' : 'completada em'} ` +
    `"${melhor.t.titulo}" (posição ${r.ordem / 10})${manual ? ' com o manual ' + manual.id : ' só com o vídeo (rotina sem manual publicado)'}.`);
}

principal().catch(e => { console.log('Erro: ' + e.message); process.exitCode = 1; });
