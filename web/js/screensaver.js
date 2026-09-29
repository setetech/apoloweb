/* ========================================================
   ApoloWeb - Protetor de tela (logotipo flutuante)

   Exibe o logotipo da loja deslizando pela tela quando o caixa fica parado
   com a venda livre. Qualquer tecla, clique ou movimento do mouse volta ao
   PDV - a tecla NAO e' consumida, entao um leitor de codigo de barras que
   dispara com a tela protegida nao perde o primeiro caractere.

   Preferencia por maquina, gravada no localStorage (mesmo padrao do tema).
   ======================================================== */

const Screensaver = {
  CHAVE_ATIVO: 'apolo_protetor_ativo',
  CHAVE_SEGUNDOS: 'apolo_protetor_segundos',
  SEGUNDOS_PADRAO: 30,
  SEGUNDOS_MIN: 5,
  SEGUNDOS_MAX: 3600,
  VELOCIDADE: 1.1, // px por frame (~66px/s a 60fps)

  _timer: null,
  _raf: null,
  _visivel: false,
  _ultimaAtividade: 0,
  _x: 0, _y: 0, _dx: 0, _dy: 0,

  init() {
    ['keydown', 'mousedown', 'wheel', 'touchstart', 'mousemove'].forEach(ev => {
      document.addEventListener(ev, () => this.registrarAtividade(), true);
    });

    this._bindConfig();
    this.aplicarConfigNaTela();
    this.agendar();
  },

  // ===== PREFERENCIAS =====
  ativo() {
    return localStorage.getItem(this.CHAVE_ATIVO) !== '0'; // padrao: ligado
  },

  segundos() {
    const s = parseInt(localStorage.getItem(this.CHAVE_SEGUNDOS), 10);
    return (s >= this.SEGUNDOS_MIN && s <= this.SEGUNDOS_MAX) ? s : this.SEGUNDOS_PADRAO;
  },

  _bindConfig() {
    const chk = document.getElementById('ss-ativo');
    const seg = document.getElementById('ss-segundos');
    if (!chk || !seg) return;

    chk.addEventListener('change', () => this._salvarConfig());
    seg.addEventListener('change', () => this._salvarConfig());
  },

  // Reflete o que esta gravado nos controles da aba Logotipo
  aplicarConfigNaTela() {
    const chk = document.getElementById('ss-ativo');
    const seg = document.getElementById('ss-segundos');
    if (!chk || !seg) return;

    chk.checked = this.ativo();
    seg.value = this.segundos();
    seg.disabled = !chk.checked;
  },

  _salvarConfig() {
    const chk = document.getElementById('ss-ativo');
    const seg = document.getElementById('ss-segundos');

    let segundos = parseInt(seg.value, 10);
    if (isNaN(segundos) || segundos < this.SEGUNDOS_MIN || segundos > this.SEGUNDOS_MAX) {
      segundos = this.SEGUNDOS_PADRAO;
      seg.value = segundos;
      Toast.warning(`Use um valor entre ${this.SEGUNDOS_MIN} e ${this.SEGUNDOS_MAX} segundos`);
    }

    localStorage.setItem(this.CHAVE_ATIVO, chk.checked ? '1' : '0');
    localStorage.setItem(this.CHAVE_SEGUNDOS, String(segundos));
    seg.disabled = !chk.checked;

    this.esconder();
    this.agendar();

    Toast.success(chk.checked
      ? `Protetor de tela ativo apos ${segundos}s de inatividade`
      : 'Protetor de tela desativado');
  },

  // O logotipo vem do mesmo arquivo usado no cupom (ver Logo.carregar).
  // Sem logo configurado, o protetor mostra o nome do sistema.
  definirLogo(dataUrl) {
    const img = document.getElementById('screensaver-logo');
    const texto = document.getElementById('screensaver-texto');
    if (!img || !texto) return;

    if (dataUrl) {
      img.src = dataUrl;
      img.classList.remove('hidden');
      texto.classList.add('hidden');
    } else {
      img.removeAttribute('src');
      img.classList.add('hidden');
      texto.classList.remove('hidden');
    }
  },

  // ===== CICLO DE INATIVIDADE =====
  registrarAtividade() {
    if (this._visivel) this.esconder();

    // mousemove dispara em rajada: rearmar no maximo 1x por segundo
    const agora = Date.now();
    if (agora - this._ultimaAtividade < 1000) return;
    this._ultimaAtividade = agora;

    this.agendar();
  },

  agendar() {
    clearTimeout(this._timer);
    if (!this.ativo()) return;
    this._timer = setTimeout(() => this.mostrar(), this.segundos() * 1000);
  },

  // So' entra com o caixa livre (antes de iniciar a venda) e sem modal aberto
  _podeExibir() {
    return this.ativo()
      && typeof ApoloApp !== 'undefined' && ApoloApp.currentView === 'view-pos'
      && typeof POS !== 'undefined' && POS.estado === 'livre'
      && Keyboard._modalStack.length === 0;
  },

  mostrar() {
    if (this._visivel) return;

    // Ainda nao pode (venda em andamento, modal aberto...): tenta de novo depois
    if (!this._podeExibir()) { this.agendar(); return; }

    const overlay = document.getElementById('screensaver');
    if (!overlay) return;

    overlay.classList.remove('hidden');
    this._visivel = true;

    // Posicao inicial aleatoria e direcao diagonal
    const caixa = document.getElementById('screensaver-box');
    const maxX = Math.max(0, overlay.clientWidth - caixa.offsetWidth);
    const maxY = Math.max(0, overlay.clientHeight - caixa.offsetHeight);
    this._x = Math.random() * maxX;
    this._y = Math.random() * maxY;
    this._dx = (Math.random() < 0.5 ? -1 : 1) * this.VELOCIDADE;
    this._dy = (Math.random() < 0.5 ? -1 : 1) * this.VELOCIDADE;

    this._animar();
  },

  esconder() {
    if (!this._visivel) return;

    const overlay = document.getElementById('screensaver');
    if (overlay) overlay.classList.add('hidden');
    cancelAnimationFrame(this._raf);
    this._visivel = false;

    // Devolver o foco ao leitor de codigo de barras
    if (typeof POS !== 'undefined' && POS.estado === 'livre') {
      const input = document.getElementById('barcode-input');
      if (input) input.focus();
    }
  },

  _animar() {
    const overlay = document.getElementById('screensaver');
    const caixa = document.getElementById('screensaver-box');
    if (!overlay || !caixa || !this._visivel) return;

    const maxX = Math.max(0, overlay.clientWidth - caixa.offsetWidth);
    const maxY = Math.max(0, overlay.clientHeight - caixa.offsetHeight);

    this._x += this._dx;
    this._y += this._dy;

    // Quicar nas bordas
    if (this._x <= 0) { this._x = 0; this._dx = Math.abs(this._dx); }
    else if (this._x >= maxX) { this._x = maxX; this._dx = -Math.abs(this._dx); }
    if (this._y <= 0) { this._y = 0; this._dy = Math.abs(this._dy); }
    else if (this._y >= maxY) { this._y = maxY; this._dy = -Math.abs(this._dy); }

    caixa.style.transform = `translate(${this._x}px, ${this._y}px)`;
    this._raf = requestAnimationFrame(() => this._animar());
  }
};
