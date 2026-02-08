/* ========================================================
   ApoloWeb - Aplicacao Principal (SPA Controller)
   ======================================================== */

const ApoloApp = {
  currentView: 'view-login',

  init() {
    // Inicializar todos os modulos
    Dialog._init();
    Keyboard.init();
    POS.init();
    Products.init();
    Customers.init();
    Payment.init();
    NFCePanel.init();
    Reports.init();
    Utils.initCurrencyMasks();

    // Bind close buttons nos modais
    document.querySelectorAll('[data-close-modal]').forEach(btn => {
      btn.addEventListener('click', () => {
        Modal.close(btn.dataset.closeModal);
      });
    });

    // Login form
    document.getElementById('btn-login').addEventListener('click', () => this.doLogin());
    document.getElementById('login-senha').addEventListener('keydown', (e) => {
      if (e.key === 'Enter') this.doLogin();
    });
    document.getElementById('login-matricula').addEventListener('keydown', (e) => {
      if (e.key === 'Enter') document.getElementById('login-senha').focus();
    });

    // Abertura de caixa
    document.getElementById('btn-abrir-caixa').addEventListener('click', () => this.doAbrirCaixa());
    document.getElementById('abertura-valor').addEventListener('keydown', (e) => {
      if (e.key === 'Enter') this.doAbrirCaixa();
    });

    // Aplicar mascaras de moeda
    Utils.applyCurrencyMask(document.getElementById('abertura-valor'));
  },

  // Trocar view
  showView(viewId) {
    document.querySelectorAll('.view').forEach(v => v.classList.remove('active'));
    const view = document.getElementById(viewId);
    if (view) {
      view.classList.add('active');
      this.currentView = viewId;

      // Focar no input correto
      setTimeout(() => {
        if (viewId === 'view-login') {
          document.getElementById('login-matricula').focus();
        } else if (viewId === 'view-abertura') {
          document.getElementById('abertura-valor').focus();
        } else if (viewId === 'view-pos') {
          document.getElementById('barcode-input').focus();
        }
      }, 200);
    }
  },

  // Sync overlay
  showSyncOverlay(text, subtext) {
    const overlay = document.getElementById('sync-overlay');
    const textEl = document.getElementById('sync-text');
    const subtextEl = document.getElementById('sync-subtext');
    if (textEl) textEl.textContent = text || 'Sincronizando dados...';
    if (subtextEl) subtextEl.textContent = subtext || 'Aguarde enquanto os dados sao atualizados';
    if (overlay) overlay.classList.remove('hidden');
  },

  hideSyncOverlay() {
    const overlay = document.getElementById('sync-overlay');
    if (overlay) overlay.classList.add('hidden');
  },

  // Login
  async doLogin() {
    const matricula = parseInt(document.getElementById('login-matricula').value) || 0;
    const senha = document.getElementById('login-senha').value;
    const errorEl = document.getElementById('login-error');

    errorEl.classList.add('hidden');

    if (!matricula) {
      errorEl.textContent = 'Informe a matricula';
      errorEl.classList.remove('hidden');
      return;
    }

    this.showSyncOverlay('Autenticando...', 'Verificando credenciais e sincronizando dados');

    try {
      const resp = await Bridge.login(matricula, senha);

      if (resp && resp.sucesso) {
        // Overlay sera fechado pelo Delphi quando a thread de sync terminar
        const dados = resp.dados;
        POS.setHeaderInfo(null, dados.nome);

        // Verificar estado do caixa
        if (dados.estadoCaixa === 0 || dados.estadoCaixa === undefined) {
          // Caixa fechado - ir para abertura
          this.showView('view-abertura');
        } else {
          // Caixa ja aberto - ir para PDV
          this.showView('view-pos');
          // Restaurar venda em andamento (recuperacao apos queda)
          if (dados.estadoCaixa >= 2 && dados.cupomAtualId > 0) {
            const estado = await Bridge.obterEstadoCaixa();
            if (estado && estado.sucesso && estado.dados.cupomAtualId > 0) {
              const numCupom = estado.dados.numCupom || 0;
              const estados = { 2: 'registrando', 3: 'pagamento' };
              POS.restaurarVenda(estado.dados.cupomAtualId, numCupom, estados[dados.estadoCaixa]);
            } else {
              POS.setEstado('livre');
            }
          } else {
            POS.setEstado('livre');
          }
        }
      } else {
        this.hideSyncOverlay();
        errorEl.textContent = (resp && resp.mensagem) || 'Erro ao realizar login';
        errorEl.classList.remove('hidden');
      }
    } catch (e) {
      this.hideSyncOverlay();
      errorEl.textContent = 'Erro de comunicacao com o sistema';
      errorEl.classList.remove('hidden');
    }
  },

  // Abrir caixa
  async doAbrirCaixa() {
    const valorStr = document.getElementById('abertura-valor').value;
    const valor = Utils.parseMoney(valorStr);

    this.showSyncOverlay('Abrindo caixa...', 'Sincronizando precos e abrindo o caixa');

    try {
      const resp = await Bridge.abrirCaixa(valor);

      if (resp && resp.sucesso) {
        // Overlay sera fechado pelo Delphi quando a thread de sync terminar
        Toast.success('Caixa aberto com sucesso');
        this.showView('view-pos');
        POS.setEstado('livre');

        // Carregar info do caixa
        const estado = await Bridge.obterEstadoCaixa();
        if (estado && estado.sucesso) {
          POS.setHeaderInfo(estado.dados.numCaixa, estado.dados.operador);
        }
      } else {
        this.hideSyncOverlay();
      }
    } catch (e) {
      this.hideSyncOverlay();
      Toast.error('Erro ao abrir caixa');
    }
  },

  // Receber mensagens do Delphi
  onMessage(action, data) {
    switch (action) {
      case 'init':
        // Dados iniciais do sistema
        if (data.operador && data.estadoCaixa > 0) {
          POS.setHeaderInfo(data.numCaixa, data.operador);
          this.showView('view-pos');
          // Restaurar venda em andamento (recuperacao apos queda)
          if (data.estadoCaixa >= 2 && data.cupomAtualId > 0) {
            const estados = { 2: 'registrando', 3: 'pagamento' };
            POS.restaurarVenda(data.cupomAtualId, data.numCupomVenda || 0, estados[data.estadoCaixa]);
          } else {
            POS.setEstado('livre');
          }
        }
        break;

      case 'keypress':
        // Tecla F pressionada no Delphi
        if (data.key) {
          Keyboard._executeAction(data.key);
        }
        break;

      case 'contingencia_update':
        // Status de contingencia mudou
        NFCePanel.atualizarStatusConexao();
        break;

      default:
        console.log('Mensagem nao tratada:', action, data);
    }
  }
};

// Inicializar quando o DOM estiver pronto
document.addEventListener('DOMContentLoaded', () => {
  ApoloApp.init();
});

// Expor globalmente para o Delphi
window.ApoloApp = ApoloApp;
