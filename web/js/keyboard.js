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

      // Alternador R$/% so' aparece via promptDesconto
      this._desc = null;
      document.getElementById('dialog-desc-tipo').classList.add('hidden');
      document.getElementById('dialog-desc-preview').classList.add('hidden');

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

  // Desconto em R$ ou % sobre 'base' (total do cupom ou valor bruto do item).
  // O % e' convertido aqui em R$ (2 casas), entao quem chama recebe sempre o
  // valor em reais: { valor, percentual (null se digitado em R$), tipo }.
  // Teclas: '%' muda para percentual, '$' volta para valor. null = cancelado.
  async promptDesconto(title, message, base) {
    const pending = this.prompt(title, message, 'Valor (R$)', '0,00');
    this._desc = { base: Math.max(0, Number(base) || 0), tipo: 'valor' };
    document.getElementById('dialog-desc-tipo').classList.remove('hidden');
    document.getElementById('dialog-desc-preview').classList.remove('hidden');
    this._setTipoDesconto('valor');

    const entrada = await pending;
    if (entrada === null || entrada === undefined) return null;

    const informado = Utils.parseMoney(String(entrada));
    const base2 = this._descBase;
    const percentual = this._descTipoFinal === 'percentual';
    return {
      tipo: this._descTipoFinal,
      percentual: percentual ? informado : null,
      valor: percentual ? Utils.round2(base2 * informado / 100) : informado
    };
  },

  _setTipoDesconto(tipo) {
    if (!this._desc) return;
    this._desc.tipo = tipo;
    document.querySelectorAll('#dialog-desc-tipo button').forEach(b =>
      b.classList.toggle('ativo', b.dataset.tipo === tipo));
    document.getElementById('dialog-input-label').textContent =
      tipo === 'percentual' ? 'Percentual (%)' : 'Valor (R$)';
    this._atualizarPreviewDesconto();
  },

  // Mostra ao vivo a equivalencia: % -> R$ ou R$ -> %, sobre a base
  _atualizarPreviewDesconto() {
    if (!this._desc) return;
    const el = document.getElementById('dialog-desc-preview');
    const { base, tipo } = this._desc;
    const informado = Utils.parseMoney(document.getElementById('dialog-input').value);
    const sobre = ' sobre ' + Utils.formatCurrency(base);
    let erro = false;
    let texto;

    if (tipo === 'percentual') {
      const valor = Utils.round2(base * informado / 100);
      erro = informado > 100;
      texto = erro ? 'Percentual maximo: 100%'
        : '= <strong>' + Utils.formatCurrency(valor) + '</strong>' + sobre;
    } else {
      erro = informado > base;
      const perc = base > 0 ? informado / base * 100 : 0;
      texto = erro ? 'Desconto maior que' + sobre.replace(' sobre', '')
        : '= <strong>' + Utils.formatMoney(perc) + '%</strong>' + sobre;
    }

    el.innerHTML = texto;
    el.classList.toggle('erro', erro);
  },

  _desc: null,
  _descBase: 0,
  _descTipoFinal: 'valor',

  _init() {
    // Capturar e limpar _resolve ANTES do Modal.close: o close tambem resolve
    // a Promise (fallback do ESC), e se ele rodar primeiro entrega null - todo
    // OK passava a responder null e as confirmacoes abortavam em silencio.
    document.getElementById('dialog-btn-ok').addEventListener('click', () => {
      const input = document.getElementById('dialog-input');
      const inputGroup = document.getElementById('dialog-input-group');
      const value = inputGroup.classList.contains('hidden') ? true : input.value;
      // Guarda o modo R$/% escolhido antes do close (promptDesconto le' depois)
      this._descTipoFinal = this._desc ? this._desc.tipo : 'valor';
      this._descBase = this._desc ? this._desc.base : 0;
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

    document.querySelectorAll('#dialog-desc-tipo button').forEach(b =>
      b.addEventListener('click', () => {
        this._setTipoDesconto(b.dataset.tipo);
        document.getElementById('dialog-input').focus();
      }));

    // Preview do desconto: setTimeout para ler o valor ja' mascarado
    document.getElementById('dialog-input').addEventListener('input', () => {
      if (this._desc) setTimeout(() => this._atualizarPreviewDesconto(), 0);
    });

    // Enter no input do dialog
    document.getElementById('dialog-input').addEventListener('keydown', (e) => {
      if (this._desc && (e.key === '%' || e.key === '$')) {
        e.preventDefault();
        this._setTipoDesconto(e.key === '%' ? 'percentual' : 'valor');
        return;
      }
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
