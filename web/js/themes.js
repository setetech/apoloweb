/* ========================================================
   ApoloWeb - Temas (skins) do PDV
   Aplica [data-theme] no <html> e persiste em localStorage.
   O tema tambem e aplicado cedo por um inline script no
   <head> do index.html para nao piscar o tema default.
   ======================================================== */

const Temas = {
  STORAGE_KEY: 'apolo_tema',

  // O preview de cada card renderiza com as variaveis do proprio tema
  // (data-theme no elemento .theme-preview) - nao precisa de cores fixas aqui.
  LISTA: [
    { id: 'escuro',     nome: 'Escuro' },
    { id: 'claro',      nome: 'Claro' },
    { id: 'meia-noite', nome: 'Meia-noite' },
    { id: 'ceu',        nome: 'Céu' },
    { id: 'floresta',   nome: 'Floresta' },
    { id: 'florido',    nome: 'Florido' },
    { id: 'oceano',     nome: 'Oceano' },
    { id: 'cafe',       nome: 'Café' }
  ],

  atual() {
    return localStorage.getItem(this.STORAGE_KEY) || 'escuro';
  },

  aplicar(id) {
    if (id === 'escuro') {
      document.documentElement.removeAttribute('data-theme');
    } else {
      document.documentElement.setAttribute('data-theme', id);
    }
    localStorage.setItem(this.STORAGE_KEY, id);
    this._marcarAtivo(id);
  },

  abrir() {
    this._render();
    Modal.open('modal-temas');
  },

  _render() {
    const grid = document.getElementById('temas-grid');
    if (!grid || grid.childElementCount > 0) {
      this._marcarAtivo(this.atual());
      return;
    }
    this.LISTA.forEach(t => {
      const card = document.createElement('div');
      card.className = 'theme-card';
      card.dataset.tema = t.id;
      card.innerHTML =
        '<div class="theme-preview" data-theme="' + t.id + '">' +
          '<div class="tp-header"><i></i><i></i></div>' +
          '<div class="tp-body">' +
            '<div class="tp-line texto"></div>' +
            '<div class="tp-line"></div>' +
            '<div class="tp-total"></div>' +
          '</div>' +
          '<div class="tp-footer">' +
            '<span class="tp-btn tp-btn-primary"></span>' +
            '<span class="tp-btn tp-btn-warning"></span>' +
            '<span class="tp-btn tp-btn-danger"></span>' +
          '</div>' +
        '</div>' +
        '<span class="theme-name">' + t.nome + '</span>';
      card.addEventListener('click', () => {
        this.aplicar(t.id);
        Toast.show('Tema "' + t.nome + '" aplicado', 'success');
      });
      grid.appendChild(card);
    });
    this._marcarAtivo(this.atual());
  },

  _marcarAtivo(id) {
    document.querySelectorAll('.theme-card').forEach(c =>
      c.classList.toggle('active', c.dataset.tema === id));
  },

  init() {
    this.aplicar(this.atual());
    const btn = document.getElementById('btn-tema');
    if (btn) btn.addEventListener('click', () => this.abrir());
    const fechar = document.getElementById('btn-temas-fechar');
    if (fechar) fechar.addEventListener('click', () => Modal.close('modal-temas'));
  }
};

Temas.init();
