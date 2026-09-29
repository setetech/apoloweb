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

    // Alt+F4 = Fechar aplicacao (deixar o browser/Delphi tratar)
    if (key === 'F4' && e.altKey) {
      Bridge.fecharApp();
      return;
    }

    // Teclas F1-F12 (com ou sem Shift: 'F3' / 'Shift+F3')
    if (/^F([1-9]|1[0-2])$/.test(key)) {
      e.preventDefault();
      this._executeAction(e.shiftKey ? 'Shift+' + key : key);
      return;
    }

    // ESC - fechar modal ou cancelar
    if (key === 'Escape') {
      e.preventDefault();
      if (this._modalStack.length > 0) {
        const modalId = this._modalStack[this._modalStack.length - 1];
        // Modal com operacao em curso (ex: TEF aguardando o pinpad). Fechar
        // aqui daria ao operador a falsa impressao de ter cancelado: quem
        // decide o que o ESC faz e' o handler 'Escape' do proprio modal (no
        // TEF, pedir o cancelamento da transacao).
        const modal = document.getElementById(modalId);
        if (modal && modal.dataset.escBloqueado === '1') {
          const handlers = this._handlers['modal_' + modalId];
          if (handlers && handlers['Escape']) handlers['Escape']();
          return;
        }
        Modal.close(modalId);
      } else {
        this._executeAction('Escape');
      }
      return;
    }

    // ENTER
    if (key === 'Enter') {
      const activeEl = document.activeElement;
      if (activeEl && activeEl.id === 'barcode-input') {
        e.preventDefault();
        POS.processarCodigo(activeEl.value);
        return;
      }
      // Delegar Enter para modal aberto (ex: pagamento)
      if (this._modalStack.length > 0) {
        e.preventDefault();
        this._executeAction('Enter');
        return;
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

      // O ESC fecha o modal por aqui, sem passar pelos botoes do Dialog. Sem
      // resolver a Promise, quem deu await em Dialog.prompt fica pendurado
      // para sempre.
      if (modalId === 'modal-dialog' && Dialog._resolve) {
        const resolver = Dialog._resolve;
        Dialog._resolve = null;
        resolver(null);
      }

      // Mesmo caso do Dialog: ESC/X fecham o QR do PIX por aqui, e quem
      // espera a confirmacao em Payment._confirmarPixQR precisa receber false
      // (alem de cancelar a cobranca dinamica pendente e parar o poll).
      if (modalId === 'modal-pix-qr' && typeof Payment !== 'undefined') {
        Payment._onPixQrFechado();
      }

      // Retornar foco ao barcode - mas so quando nao sobrou modal aberto por
      // baixo (ex: o QR do PIX pelo TEF fecha em cima do modal de pagamento,
      // e o foco tem de ficar la, nao no PDV atras)
      if (Keyboard._modalStack.length === 0) {
        const barcodeInput = document.getElementById('barcode-input');
        if (barcodeInput) setTimeout(() => barcodeInput.focus(), 100);
      }
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

  async prompt(title, message, inputLabel = '', defaultValue = '', useMask = true, inputType = 'text') {
    return new Promise((resolve) => {
      this._resolve = resolve;

      document.getElementById('dialog-title').textContent = title;
      document.getElementById('dialog-message').textContent = message;

      const inputGroup = document.getElementById('dialog-input-group');
      const input = document.getElementById('dialog-input');

      // 'password' oculta a digitacao (ex: senha do autorizador)
      input.type = inputType;

      // Ativar/desativar mascara monetaria
      input.dataset.masked = useMask ? '1' : '0';
      if (useMask) {
        input.classList.add('input-currency');
      } else {
        input.classList.remove('input-currency');
      }

      if (inputLabel) {
        inputGroup.classList.remove('hidden');
        document.getElementById('dialog-input-label').textContent = inputLabel;
        input.value = defaultValue;
      } else {
        inputGroup.classList.add('hidden');
      }

      Modal.open('modal-dialog');

      // select() para que um valor ja sugerido possa ser substituido apenas
      // digitando - sem ele a mascara monetaria concatena os digitos novos no
      // fim do valor antigo.
      if (inputLabel) setTimeout(() => { input.focus(); input.select(); }, 150);
    });
  },

  async confirm(title, message) {
    return this.prompt(title, message);
  },

  _init() {
    // Capturar e limpar _resolve ANTES do Modal.close: o close tambem resolve
    // a Promise (fallback do ESC), e se ele rodar primeiro entrega null - todo
    // OK passava a responder null e as confirmacoes abortavam em silencio.
    document.getElementById('dialog-btn-ok').addEventListener('click', () => {
      const input = document.getElementById('dialog-input');
      const inputGroup = document.getElementById('dialog-input-group');
      const value = inputGroup.classList.contains('hidden') ? true : input.value;
      const resolver = this._resolve;
      this._resolve = null;
      Modal.close('modal-dialog');
      if (resolver) resolver(value);
    });

    document.getElementById('dialog-btn-cancel').addEventListener('click', () => {
      const resolver = this._resolve;
      this._resolve = null;
      Modal.close('modal-dialog');
      if (resolver) resolver(null);
    });

    // Enter no input do dialog
    document.getElementById('dialog-input').addEventListener('keydown', (e) => {
      if (e.key === 'Enter') {
        e.preventDefault();
        // stopPropagation e' obrigatorio: o clique em OK ja tirou o dialog da
        // pilha, entao o handler global veria este mesmo Enter e o entregaria
        // ao modal de baixo - no pagamento isso disparava um registrarPagamento
        // extra em cima do painel ativo.
        e.stopPropagation();
        document.getElementById('dialog-btn-ok').click();
      }
    });
  }
};
