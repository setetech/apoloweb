/* ========================================================
   ApoloWeb - Mapeamento de Teclas F1-F12
   ======================================================== */

const Keyboard = {
  _handlers: {},
  _modalStack: [],

  init() {
    document.addEventListener('keydown', (e) => this._handleKey(e));

    // Clicks nos botoes de funcao
    document.querySelectorAll('.fkey').forEach(btn => {
      btn.addEventListener('click', () => {
        const key = btn.dataset.key;
        if (key) this._executeAction(key);
      });
    });
  },

  _handleKey(e) {
    const key = e.key;

    // Teclas F1-F12
    if (key >= 'F1' && key <= 'F12') {
      e.preventDefault();
      this._executeAction(key);
      return;
    }

    // ESC - fechar modal ou cancelar
    if (key === 'Escape') {
      e.preventDefault();
      if (this._modalStack.length > 0) {
        const modalId = this._modalStack[this._modalStack.length - 1];
        Modal.close(modalId);
      } else {
        this._executeAction('Escape');
      }
      return;
    }

    // ENTER no barcode input
    if (key === 'Enter') {
      const activeEl = document.activeElement;
      if (activeEl && activeEl.id === 'barcode-input') {
        e.preventDefault();
        POS.processarCodigo(activeEl.value);
      }
    }
  },

  _executeAction(key) {
    // Se ha um modal aberto, delegar para o handler do modal
    if (this._modalStack.length > 0) {
      const modalId = this._modalStack[this._modalStack.length - 1];
      const modalHandlers = this._handlers['modal_' + modalId];
      if (modalHandlers && modalHandlers[key]) {
        modalHandlers[key]();
        return;
      }
    }

    // Handler global da view ativa
    const handler = this._handlers['global'];
    if (handler && handler[key]) {
      handler[key]();
    }
  },

  // Registrar handlers para uma view/modal
  register(context, handlers) {
    this._handlers[context] = handlers;
  },

  pushModal(modalId) {
    this._modalStack.push(modalId);
  },

  popModal(modalId) {
    const idx = this._modalStack.indexOf(modalId);
    if (idx !== -1) this._modalStack.splice(idx, 1);
  }
};

// Sistema de Modais
const Modal = {
  open(modalId) {
    const modal = document.getElementById(modalId);
    if (modal) {
      modal.classList.remove('hidden');
      modal.classList.add('animate-fadeIn');
      Keyboard.pushModal(modalId);

      // Focar no primeiro input
      const firstInput = modal.querySelector('input:not([type=hidden])');
      if (firstInput) setTimeout(() => firstInput.focus(), 100);
    }
  },

  close(modalId) {
    const modal = document.getElementById(modalId);
    if (modal) {
      modal.classList.add('hidden');
      Keyboard.popModal(modalId);

      // Retornar foco ao barcode
      const barcodeInput = document.getElementById('barcode-input');
      if (barcodeInput) setTimeout(() => barcodeInput.focus(), 100);
    }
  },

  isOpen(modalId) {
    const modal = document.getElementById(modalId);
    return modal && !modal.classList.contains('hidden');
  }
};

// Dialogo generico
const Dialog = {
  _resolve: null,

  async prompt(title, message, inputLabel = '', defaultValue = '') {
    return new Promise((resolve) => {
      this._resolve = resolve;

      document.getElementById('dialog-title').textContent = title;
      document.getElementById('dialog-message').textContent = message;

      const inputGroup = document.getElementById('dialog-input-group');
      const input = document.getElementById('dialog-input');

      if (inputLabel) {
        inputGroup.classList.remove('hidden');
        document.getElementById('dialog-input-label').textContent = inputLabel;
        input.value = defaultValue;
      } else {
        inputGroup.classList.add('hidden');
      }

      Modal.open('modal-dialog');

      if (inputLabel) setTimeout(() => input.focus(), 150);
    });
  },

  async confirm(title, message) {
    return this.prompt(title, message);
  },

  _init() {
    document.getElementById('dialog-btn-ok').addEventListener('click', () => {
      const input = document.getElementById('dialog-input');
      const inputGroup = document.getElementById('dialog-input-group');
      const value = inputGroup.classList.contains('hidden') ? true : input.value;
      Modal.close('modal-dialog');
      if (this._resolve) { this._resolve(value); this._resolve = null; }
    });

    document.getElementById('dialog-btn-cancel').addEventListener('click', () => {
      Modal.close('modal-dialog');
      if (this._resolve) { this._resolve(null); this._resolve = null; }
    });

    // Enter no input do dialog
    document.getElementById('dialog-input').addEventListener('keydown', (e) => {
      if (e.key === 'Enter') {
        e.preventDefault();
        document.getElementById('dialog-btn-ok').click();
      }
    });
  }
};
