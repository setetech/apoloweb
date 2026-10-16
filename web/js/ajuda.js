/* ========================================================
   ApoloWeb - Ajuda do PDV
   Duplo clique no logotipo (login ou cabecalho do PDV) abre o manual do
   operador (#modal-ajuda). Sumario e busca sao montados aqui a partir dos
   <section>/<h2> do index.html - o texto fica so no HTML, que tambem e a
   fonte da base de conhecimento (skill colosso-ajuda-rag).
   ======================================================== */

const Ajuda = {
  _secoes: [],

  init() {
    ['.login-logo', '#pos-logo-img', '#pos-logo-texto'].forEach(sel => {
      const el = document.querySelector(sel);
      if (!el) return;
      el.classList.add('ajuda-gatilho');
      el.title = 'Clique duas vezes para abrir a ajuda';
      el.addEventListener('dblclick', (e) => {
        e.preventDefault();
        this.abrir();
      });
    });

    this._montarSumario();

    const filtro = document.getElementById('ajuda-filtro');
    filtro.addEventListener('input', () => this._filtrar(filtro.value));
    // Enter na busca nao pode subir: o Keyboard entrega o Enter ao modal do topo
    filtro.addEventListener('keydown', (e) => {
      if (e.key === 'Enter') { e.preventDefault(); e.stopPropagation(); }
    });

    document.getElementById('ajuda-texto').addEventListener('scroll', () => this._marcarAtivo());

    // Com a ajuda aberta, as teclas de funcao nao podem disparar a acao do PDV
    // que esta atras: quando o modal do topo nao trata a tecla, o Keyboard cai
    // no handler global. O ESC fecha pelo caminho padrao do Modal.
    const nada = () => {};
    const teclas = { 'Enter': nada };
    for (let i = 1; i <= 12; i++) {
      teclas['F' + i] = nada;
      teclas['Shift+F' + i] = nada;
    }
    Keyboard.register('modal_modal-ajuda', teclas);
  },

  abrir() {
    if (Modal.isOpen('modal-ajuda')) return;
    document.getElementById('ajuda-filtro').value = '';
    this._filtrar('');
    Modal.open('modal-ajuda');
    // Com o modal escondido as posicoes sao todas zero: marcar so depois de abrir
    requestAnimationFrame(() => this._marcarAtivo());
  },

  _montarSumario() {
    const nav = document.getElementById('ajuda-sumario');
    nav.innerHTML = '';
    this._secoes = Array.from(document.querySelectorAll('#ajuda-texto section')).map(sec => {
      const h2 = sec.querySelector('h2');
      const link = document.createElement('a');
      link.textContent = h2 ? h2.textContent : sec.id;
      link.addEventListener('click', () => sec.scrollIntoView({ behavior: 'smooth', block: 'start' }));
      nav.appendChild(link);
      return { sec, link, texto: this._normalizar(sec.textContent) };
    });
  },

  // Busca sem acento e sem caixa: "funcao" acha "Função"
  _normalizar(s) {
    return String(s || '').normalize('NFD').replace(/[̀-ͯ]/g, '').toLowerCase();
  },

  _filtrar(termo) {
    const t = this._normalizar(termo).trim();
    let algum = false;
    this._secoes.forEach(({ sec, link, texto }) => {
      const casa = !t || texto.includes(t);
      sec.classList.toggle('hidden', !casa);
      link.classList.toggle('hidden', !casa);
      if (casa) algum = true;
      // Pergunta frequente que tem o termo ja aparece aberta
      sec.querySelectorAll('details').forEach(d => {
        d.open = !!t && this._normalizar(d.textContent).includes(t);
      });
    });
    document.getElementById('ajuda-vazio').classList.toggle('hidden', algum);
    document.getElementById('ajuda-texto').scrollTop = 0;
    this._marcarAtivo();
  },

  // Destaca no sumario a secao que esta no topo da area de texto
  _marcarAtivo() {
    const topo = document.getElementById('ajuda-texto').getBoundingClientRect().top + 24;
    let atual = null;
    this._secoes.forEach(s => {
      if (s.sec.classList.contains('hidden')) return;
      if (!atual || s.sec.getBoundingClientRect().top <= topo) atual = s;
    });
    this._secoes.forEach(s => s.link.classList.toggle('ativo', s === atual));
  }
};
