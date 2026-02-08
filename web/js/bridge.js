/* ========================================================
   ApoloWeb - Bridge de comunicacao com Delphi
   ======================================================== */

const Bridge = {
  _callbackCounter: 0,

  // Enviar mensagem para o Delphi via postMessage
  async send(action, data = {}) {
    return new Promise((resolve, reject) => {
      try {
        const callbackId = 'cb_' + (++this._callbackCounter);

        // Registrar callback
        if (!window.__apoloCallbacks) window.__apoloCallbacks = {};
        window.__apoloCallbacks[callbackId] = (result) => {
          delete window.__apoloCallbacks[callbackId];
          resolve(result);
        };

        // Timeout de seguranca
        setTimeout(() => {
          if (window.__apoloCallbacks[callbackId]) {
            delete window.__apoloCallbacks[callbackId];
            reject(new Error('Timeout na comunicacao com o backend'));
          }
        }, 30000);

        const message = JSON.stringify({
          action: action,
          data: JSON.stringify(data),
          callbackId: callbackId
        });

        // Enviar via WebView2
        if (window.chrome && window.chrome.webview) {
          window.chrome.webview.postMessage(message);
        } else {
          // Modo dev/simulacao - rejeitar graciosamente
          delete window.__apoloCallbacks[callbackId];
          resolve({ sucesso: false, mensagem: 'WebView nao disponivel (modo desenvolvimento)', dados: {} });
        }
      } catch (err) {
        reject(err);
      }
    });
  },

  // Atalho para enviar e processar resposta
  async call(action, data = {}) {
    const response = await this.send(action, data);
    if (response && !response.sucesso) {
      Toast.error(response.mensagem || 'Erro desconhecido');
    }
    return response;
  },

  // Login
  async login(matricula, senha) {
    return this.call('login', { matricula, senha });
  },

  // Produtos
  async buscarProduto(codigo) {
    return this.call('buscarProduto', { codigo });
  },

  async listarProdutos(filtro) {
    return this.call('listarProdutos', { filtro });
  },

  // Venda
  async iniciarVenda() {
    return this.call('iniciarVenda', {});
  },

  async adicionarItem(codprod, quantidade = 1, precoManual = 0, codvendedor = 0) {
    return this.call('adicionarItem', { codprod, quantidade, precoManual, codvendedor });
  },

  async removerItem(numSeqItem) {
    return this.call('removerItem', { numSeqItem });
  },

  async aplicarDesconto(valor, tipo = 'valor') {
    return this.call('aplicarDesconto', { valor, tipo });
  },

  async cancelarVenda() {
    return this.call('cancelarVenda', {});
  },

  async obterItensCupom() {
    return this.call('obterItensCupom', {});
  },

  async obterResumoCupom() {
    return this.call('obterResumoCupom', {});
  },

  // Pagamento
  async registrarPagamento(dadosPagamento) {
    return this.call('registrarPagamento', dadosPagamento);
  },

  async removerPagamento(id) {
    return this.call('removerPagamento', { id });
  },

  async finalizarVenda() {
    return this.call('finalizarVenda', {});
  },

  async listarMeiosPagamento() {
    return this.call('listarMeiosPagamento', {});
  },

  async obterResumoPagamento() {
    return this.call('obterResumoPagamento', {});
  },

  // Caixa
  async abrirCaixa(valorSuprimento) {
    return this.call('abrirCaixa', { valorSuprimento });
  },

  async fecharCaixa() {
    return this.call('fecharCaixa', {});
  },

  async efetuarSangria(valor, motivo) {
    return this.call('efetuarSangria', { valor, motivo });
  },

  async efetuarSuprimento(valor) {
    return this.call('efetuarSuprimento', { valor });
  },

  async obterEstadoCaixa() {
    return this.call('obterEstadoCaixa', {});
  },

  // NFCe
  async gerarNFCe(cupomId) {
    return this.call('gerarNFCe', { cupomId });
  },

  async listarNFCePendentes() {
    return this.call('listarNFCePendentes', {});
  },

  async retransmitirContingencia() {
    return this.call('retransmitirContingencia', {});
  },

  // Contingencia
  async obterStatusConexao() {
    return this.call('obterStatusConexao', {});
  },

  async entrarContingencia(tipo, justificativa) {
    return this.call('entrarContingencia', { tipo, justificativa });
  },

  async sairContingencia() {
    return this.call('sairContingencia', {});
  },

  // Clientes
  async buscarCliente(filtro) {
    return this.call('buscarCliente', { filtro });
  },

  async identificarConsumidor(cpfCnpj) {
    return this.call('identificarConsumidor', { cpfCnpj });
  },

  async vincularCliente(codcli) {
    return this.call('vincularCliente', { codcli });
  },

  // Pre-venda
  async listarPreVendas() {
    return this.call('listarPreVendas', {});
  },

  async importarPreVenda(numtrans) {
    return this.call('importarPreVenda', { numtrans });
  }
};

// Sistema de Toast/Notificacoes
const Toast = {
  show(message, type = 'info', duration = 3000) {
    const container = document.getElementById('toast-container');
    const toast = document.createElement('div');
    toast.className = `toast toast-${type}`;
    toast.textContent = message;
    container.appendChild(toast);

    setTimeout(() => {
      toast.style.animation = 'fadeOut 0.3s ease forwards';
      setTimeout(() => toast.remove(), 300);
    }, duration);
  },

  success(msg) { this.show(msg, 'success'); },
  error(msg) { this.show(msg, 'error', 5000); },
  warning(msg) { this.show(msg, 'warning', 4000); },
  info(msg) { this.show(msg, 'info'); }
};
