/* ========================================================
   Apolo Menu - telas de login, menu de rotinas e configuracao
   Nenhuma regra mora aqui: login, liberacao e abertura da rotina sao
   decididos no Rust/Oracle. A tela so' pede e mostra.
   ======================================================== */

const $ = (id) => document.getElementById(id);

const Estado = {
  usuario: null,
  rotinas: [],
  visiveis: [],
  selecionada: -1,
  servidor: ''
};

// ---------- utilidades ----------

function toast(msg, tipo = 'info') {
  const el = document.createElement('div');
  el.className = 'toast ' + tipo;
  el.textContent = msg;
  $('toasts').appendChild(el);
  setTimeout(() => el.remove(), tipo === 'erro' ? 6000 : 3500);
}

function status(msg) { $('status-msg').textContent = msg; }

function normalizar(s) {
  return String(s || '').normalize('NFD').replace(/[̀-ͯ]/g, '').toLowerCase();
}

function mostrarTela(id) {
  document.querySelectorAll('.tela').forEach((t) => t.classList.toggle('ativa', t.id === id));
}

async function chamar(promessa) {
  try {
    return await promessa;
  } catch (e) {
    return { sucesso: false, mensagem: e.message, dados: {} };
  }
}

// ---------- recentes (conveniencia local, por matricula) ----------

const Recentes = {
  _chave() { return 'apolomenu.recentes.' + (Estado.usuario ? Estado.usuario.matricula : ''); },
  ler() {
    try { return JSON.parse(localStorage.getItem(this._chave()) || '[]'); } catch (e) { return []; }
  },
  registrar(cod) {
    const lista = [cod].concat(this.ler().filter((c) => c !== cod)).slice(0, 10);
    try { localStorage.setItem(this._chave(), JSON.stringify(lista)); } catch (e) { /* sem storage */ }
  }
};

function renderRecentes() {
  const ul = $('recentes');
  ul.replaceChildren();
  const porCodigo = new Map(Estado.rotinas.map((r) => [r.codrotina, r]));
  const itens = Recentes.ler().map((c) => porCodigo.get(c)).filter(Boolean);
  $('recentes-box').hidden = itens.length === 0;
  itens.forEach((r) => {
    const li = document.createElement('li');
    const b = document.createElement('b');
    b.textContent = r.codrotina;
    li.append(b, document.createTextNode(r.nome));
    li.title = r.codrotina + ' - ' + r.nome;
    li.addEventListener('click', () => executar(r.codrotina));
    ul.appendChild(li);
  });
}

// ---------- login ----------

async function entrar(ev) {
  ev.preventDefault();
  const login = $('login-usuario').value.trim();
  const senha = $('login-senha').value;
  $('login-erro').textContent = '';
  if (!login) { $('login-usuario').focus(); return; }

  $('btn-entrar').disabled = true;
  $('btn-entrar').textContent = 'Entrando...';
  const r = await chamar(Bridge.login(login, senha));
  $('btn-entrar').disabled = false;
  $('btn-entrar').textContent = 'Entrar';

  if (!r.sucesso) {
    $('login-erro').textContent = r.mensagem;
    $('login-senha').select();
    return;
  }
  $('login-senha').value = '';
  abrirMenu(r.dados.usuario);
}

async function trocarUsuario() {
  await chamar(Bridge.logout());
  Estado.usuario = null;
  Estado.rotinas = [];
  $('login-usuario').value = '';
  $('login-senha').value = '';
  $('login-erro').textContent = '';
  mostrarTela('tela-login');
  $('login-usuario').focus();
}

// ---------- menu ----------

async function abrirMenu(usuario) {
  Estado.usuario = usuario;
  $('menu-usuario').textContent = usuario.matricula + ' - ' + usuario.nome;
  $('status-servidor').textContent = Estado.servidor;
  $('busca').value = '';
  mostrarTela('tela-menu');
  $('busca').focus();
  await carregarRotinas();
}

async function carregarRotinas() {
  status('Carregando rotinas...');
  const r = await chamar(Bridge.listarRotinas());
  if (!r.sucesso) {
    status('Falha ao carregar rotinas');
    toast(r.mensagem, 'erro');
    Estado.rotinas = [];
  } else {
    Estado.rotinas = r.dados.rotinas || [];
    status(Estado.rotinas.length + ' rotina(s) liberada(s)');
  }
  filtrar();
  renderRecentes();
}

function filtrar() {
  const termo = $('busca').value.trim();
  const t = normalizar(termo);
  if (!termo) {
    Estado.visiveis = Estado.rotinas.slice();
  } else if (/^\d+$/.test(termo)) {
    Estado.visiveis = Estado.rotinas.filter((r) => String(r.codrotina).startsWith(termo));
  } else {
    Estado.visiveis = Estado.rotinas.filter((r) =>
      normalizar(r.nome).includes(t) || normalizar(r.modulo).includes(t));
  }
  Estado.selecionada = Estado.visiveis.length ? 0 : -1;
  renderLista();
}

function renderLista() {
  const lista = $('lista');
  lista.replaceChildren();
  $('busca-total').textContent = Estado.visiveis.length + ' de ' + Estado.rotinas.length;

  if (!Estado.visiveis.length) {
    const vazio = document.createElement('div');
    vazio.className = 'vazio';
    vazio.textContent = Estado.rotinas.length
      ? 'Nenhuma rotina encontrada. Enter abre o codigo digitado, se for liberado.'
      : 'Nenhuma rotina liberada para este usuario.';
    lista.appendChild(vazio);
    return;
  }

  let grupoAtual = null;
  let container = lista;
  Estado.visiveis.forEach((r, i) => {
    const modulo = r.modulo || '';
    if (modulo !== grupoAtual) {
      grupoAtual = modulo;
      container = document.createElement('div');
      container.className = 'grupo';
      if (modulo) {
        const h = document.createElement('h3');
        h.textContent = modulo;
        container.appendChild(h);
      }
      lista.appendChild(container);
    }
    const linha = document.createElement('div');
    linha.className = 'rotina' + (i === Estado.selecionada ? ' selecionada' : '');
    linha.dataset.indice = i;
    const cod = document.createElement('span');
    cod.className = 'cod';
    cod.textContent = r.codrotina;
    const nome = document.createElement('span');
    nome.textContent = r.nome;
    linha.append(cod, nome);
    linha.addEventListener('click', () => selecionar(i));
    linha.addEventListener('dblclick', () => executar(r.codrotina));
    container.appendChild(linha);
  });
}

function selecionar(i) {
  if (!Estado.visiveis.length) return;
  Estado.selecionada = Math.max(0, Math.min(i, Estado.visiveis.length - 1));
  document.querySelectorAll('.rotina').forEach((el) =>
    el.classList.toggle('selecionada', Number(el.dataset.indice) === Estado.selecionada));
  const el = document.querySelector('.rotina.selecionada');
  if (el) el.scrollIntoView({ block: 'nearest' });
}

let executando = false;
async function executar(codrotina) {
  if (executando) return;
  executando = true;
  status('Abrindo rotina ' + codrotina + '...');
  const r = await chamar(Bridge.executarRotina(codrotina));
  executando = false;
  if (r.sucesso) {
    status(r.mensagem);
    toast(r.mensagem, 'ok');
    Recentes.registrar(Number(codrotina));
    renderRecentes();
  } else {
    status('Pronto');
    toast(r.mensagem, 'erro');
  }
}

function teclaBusca(ev) {
  if (ev.key === 'ArrowDown') { ev.preventDefault(); selecionar(Estado.selecionada + 1); }
  else if (ev.key === 'ArrowUp') { ev.preventDefault(); selecionar(Estado.selecionada - 1); }
  else if (ev.key === 'PageDown') { ev.preventDefault(); selecionar(Estado.selecionada + 10); }
  else if (ev.key === 'PageUp') { ev.preventDefault(); selecionar(Estado.selecionada - 10); }
  else if (ev.key === 'Escape') { $('busca').value = ''; filtrar(); }
  else if (ev.key === 'Enter') {
    ev.preventDefault();
    const termo = $('busca').value.trim();
    const exato = Estado.visiveis.some((r) => String(r.codrotina) === termo);
    // Codigo completo abre direto; codigo fora da lista tambem vai ao Rust,
    // que confere no Oracle (a lista pode estar desatualizada)
    if (/^\d+$/.test(termo) && (exato || Estado.visiveis.length !== 1)) {
      executar(Number(termo));
    } else if (Estado.selecionada >= 0) {
      executar(Estado.visiveis[Estado.selecionada].codrotina);
    }
  }
}

// ---------- configuracao ----------

async function abrirConfig() {
  const r = await chamar(Bridge.obterConfig());
  const d = r.dados || {};
  $('cfg-server').value = d.server || '';
  $('cfg-port').value = d.port || '';
  $('cfg-timeout').value = d.timeout || '';
  $('cfg-username').value = d.username || '';
  $('cfg-password').value = '';
  $('cfg-password').placeholder = d.temSenha ? '(mantida - preencha para trocar)' : '';
  $('cfg-admin').value = '';
  $('cfg-status').textContent = '';
  $('cfg-status').className = 'info';
  $('cfg-verificacoes').replaceChildren();
  $('cfg-arquivo').textContent = d.arquivoIni ? 'Grava em: ' + d.arquivoIni : '';
  $('modal-config').hidden = false;
  $('cfg-server').focus();
}

function fecharConfig() {
  $('modal-config').hidden = true;
  $('login-usuario').focus();
}

function dadosConfig() {
  return {
    server: $('cfg-server').value.trim(),
    port: $('cfg-port').value.trim(),
    timeout: $('cfg-timeout').value.trim(),
    username: $('cfg-username').value.trim(),
    password: $('cfg-password').value,
    senhaAdmin: $('cfg-admin').value
  };
}

function statusConfig(msg, classe) {
  $('cfg-status').textContent = msg;
  $('cfg-status').className = 'info ' + (classe || '');
}

async function testarConexao() {
  statusConfig('Testando conexao...');
  $('btn-testar').disabled = true;
  const r = await chamar(Bridge.testarConexao(dadosConfig()));
  $('btn-testar').disabled = false;
  const lista = $('cfg-verificacoes');
  lista.replaceChildren();
  if (!r.sucesso) {
    statusConfig(r.mensagem, 'falha');
    return;
  }
  const d = r.dados;
  const extras = [d.versao && 'Oracle ' + d.versao, d.charset].filter(Boolean).join(' - ');
  statusConfig(r.mensagem + (extras ? ' (' + extras + ')' : ''), d.falhas ? 'falha' : 'ok');
  (d.verificacoes || []).forEach((v) => {
    const li = document.createElement('li');
    li.className = v.ok ? 'ok' : 'falha';
    li.textContent = (v.ok ? '\u2713 ' : '\u2717 ') + 'SQL ' + v.nome + (v.ok ? '' : ': ' + v.mensagem);
    li.title = li.textContent;
    lista.appendChild(li);
  });
}

async function salvarConfig(ev) {
  ev.preventDefault();
  const r = await chamar(Bridge.salvarConfig(dadosConfig()));
  if (!r.sucesso) {
    statusConfig(r.mensagem, 'falha');
    return;
  }
  toast('Configuracao salva', 'ok');
  fecharConfig();
  await iniciar();
}

// ---------- inicio ----------

async function iniciar() {
  const r = await chamar(Bridge.iniciar());
  const d = r.dados || {};
  Estado.servidor = d.servidor ? 'Oracle: ' + d.servidor : '';
  $('login-servidor').textContent = Estado.servidor || 'Conexao nao configurada';

  if (d.usuario) {
    abrirMenu(d.usuario);
  } else {
    mostrarTela('tela-login');
    $('login-usuario').focus();
    if (r.sucesso && !d.configurado) abrirConfig();
  }
}

document.addEventListener('DOMContentLoaded', () => {
  $('form-login').addEventListener('submit', entrar);
  $('btn-config').addEventListener('click', abrirConfig);
  $('btn-trocar').addEventListener('click', trocarUsuario);
  $('btn-sair').addEventListener('click', () => Bridge.fecharApp());
  $('busca').addEventListener('input', filtrar);
  $('busca').addEventListener('keydown', teclaBusca);
  $('form-config').addEventListener('submit', salvarConfig);
  $('btn-testar').addEventListener('click', testarConexao);
  $('btn-cancelar').addEventListener('click', fecharConfig);

  document.addEventListener('keydown', (ev) => {
    if (ev.key === 'Escape' && !$('modal-config').hidden) { fecharConfig(); return; }
    if (ev.key === 'F5') {
      ev.preventDefault();
      if (Estado.usuario) carregarRotinas();
    }
    // Digitar em qualquer lugar do menu cai na busca
    if ($('tela-menu').classList.contains('ativa') && $('modal-config').hidden
        && document.activeElement !== $('busca') && ev.key.length === 1 && !ev.ctrlKey && !ev.altKey) {
      $('busca').focus();
    }
  });

  // Sem menu de contexto do navegador: e' um aplicativo, nao uma pagina
  document.addEventListener('contextmenu', (ev) => {
    if (!(ev.target instanceof HTMLInputElement)) ev.preventDefault();
  });

  iniciar();
});
