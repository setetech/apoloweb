/* ========================================================
   ApoloWeb - Bridge de comunicacao com Delphi
   ======================================================== */

const Bridge = {
  _callbackCounter: 0,

  // Timeout de seguranca padrao. O Delphi processa as acoes na thread
  // principal e SEMPRE responde (erro vira resposta sucesso=false), entao o
  // timeout so' dispara se o app estiver travado de verdade.
  TIMEOUT_PADRAO_MS: 120000,

  // Acoes que falam com Oracle/SEFAZ/TEF/impressora e podem legitimamente
  // passar de 30 s. Em 11/09/2026 o upload da venda 312 levou 45 s (Oracle
  // lento), o timeout de 30 s rejeitou a Promise do finalizarVenda, o front
  // nunca chamou o gerarNFCe e a venda ficou fechada sem nota - com o
  // operador preso no modal de pagamento. Rejeitar aqui nao destrava nada:
  // o Delphi continua ocupado do mesmo jeito, so' perde-se a resposta.
  TIMEOUT_LONGO_MS: 600000,
  _acoesLongas: {
    finalizarVenda: true, gerarNFCe: true, cancelarNFCe: true,
    regerarNFCeRejeitadas: true, retransmitirContingencia: true,
    abrirCaixa: true, fecharCaixa: true, login: true,
    reimprimirCupom: true, reimprimirComprovanteTEF: true,
    cancelarVenda: true, administracaoTEF: true, estornarTEF: true,
    iniciarPagamentoTEF: true, testarTEF: true, testarImpressao: true,
    efetuarSangria: true, efetuarSuprimento: true
  },

  _timeoutPara(action) {
    return this._acoesLongas[action] ? this.TIMEOUT_LONGO_MS : this.TIMEOUT_PADRAO_MS;
  },

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
            reject(new Error('Timeout na comunicacao com o backend (' + action + ')'));
          }
        }, this._timeoutPara(action));

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

  async adicionarItem(codprod, quantidade = 1, precoManual = 0, codvendedor = 0, codbarra = '', precoEtiqueta = 0) {
    return this.call('adicionarItem', { codprod, quantidade, precoManual, codvendedor, codbarra, precoEtiqueta });
  },

  // aut = { supMatricula, supSenha } quando o backend exigir autorizacao
  async removerItem(numSeqItem, aut = null) {
    return this.call('removerItem', Object.assign({ numSeqItem }, aut || {}));
  },

  // Desconto no TOTAL da venda.
  // aut = { supMatricula, supSenha } quando o backend exigir autorizacao
  async aplicarDesconto(valor, tipo = 'valor', aut = null) {
    return this.call('aplicarDesconto', Object.assign({ valor, tipo }, aut || {}));
  },

  // Desconto em UM item do cupom. valor = 0 remove o desconto.
  // aut = { supMatricula, supSenha } quando o backend exigir autorizacao
  async aplicarDescontoItem(numSeqItem, valor, tipo = 'valor', aut = null) {
    return this.call('aplicarDescontoItem', Object.assign({ numSeqItem, valor, tipo }, aut || {}));
  },

  // aut = { supMatricula, supSenha } quando o backend exigir autorizacao
  async cancelarVenda(aut = null) {
    return this.call('cancelarVenda', Object.assign({}, aut || {}));
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

  async listarBandeiras() {
    return this.call('listarBandeiras', {});
  },

  async listarMeioPagto() {
    return this.call('listarMeioPagto', {});
  },

  async listarPlanosPagamento() {
    return this.call('listarPlanosPagamento', {});
  },

  async obterResumoPagamento() {
    return this.call('obterResumoPagamento', {});
  },

  // PIX manual: payload BR Code com a chave da filial (msfilial.chave_pix).
  // send (e nao call) para o chamador decidir como tratar chave ausente.
  async obterPixQRCode(valor) {
    return this.send('obterPixQRCode', { valor });
  },

  // payload: copia-e-cola da cobranca dinamica; vazio = QR estatico
  async imprimirPixQRCode(valor, payload) {
    return this.call('imprimirPixQRCode', { valor, payload: payload || '' });
  },

  // PIX dinamico (API Pix via ACBrPIXCD). send em todos: "nao configurada"
  // e resposta normal de quem nao usa a API, nao merece toast de erro.
  async iniciarCobrancaPix(valor) {
    return this.send('iniciarCobrancaPix', { valor });
  },

  async consultarCobrancaPix(txid) {
    return this.send('consultarCobrancaPix', { txid });
  },

  async cancelarCobrancaPix(txid) {
    return this.send('cancelarCobrancaPix', { txid });
  },

  // Caixa
  async abrirCaixa(valorSuprimento) {
    return this.call('abrirCaixa', { valorSuprimento });
  },

  // aut = { supMatricula, supSenha } quando o backend exigir autorizacao
  async fecharCaixa(aut = null) {
    return this.call('fecharCaixa', Object.assign({}, aut || {}));
  },

  // aut = { supMatricula, supSenha } quando o backend exigir autorizacao
  async efetuarSangria(valor, motivo, aut = null) {
    return this.call('efetuarSangria', Object.assign({ valor, motivo }, aut || {}));
  },

  async efetuarSuprimento(valor) {
    return this.call('efetuarSuprimento', { valor });
  },

  // Imprime as vias do comprovante confirmadas no preview (sangria/suprimento)
  async imprimirComprovante(vias) {
    return this.call('imprimirComprovante', { vias });
  },

  async obterEstadoCaixa() {
    return this.call('obterEstadoCaixa', {});
  },

  // NFCe
  // manual=true: emissao pela tela Documentos Fiscais de uma venda que fechou
  // sem nota (o Delphi so' loga a origem; a validacao e' a mesma)
  async gerarNFCe(cupomId, manual = false) {
    return this.call('gerarNFCe', { cupomId, manual });
  },

  // Regera do cupom as notas rejeitadas marcadas (mesmo numero, chave nova).
  // Diferente de retransmitirContingencia, que reenvia o XML ja negado.
  async regerarNFCeRejeitadas(ids) {
    return this.call('regerarNFCeRejeitadas', { ids });
  },

  async listarNFCePendentes() {
    return this.call('listarNFCePendentes', {});
  },

  // ids = ids da nfce_contingencia. So documento REJEITADO sai da fila; o
  // Delphi refaz esse filtro antes de gravar.
  async descartarNFCePendentes(ids) {
    return this.call('descartarNFCePendentes', { ids });
  },

  async retransmitirContingencia() {
    return this.call('retransmitirContingencia', {});
  },

  // Notas autorizadas do dia, com os minutos decorridos desde a venda
  // (a SEFAZ so homologa cancelamento de NFCe dentro de 30 minutos)
  async listarNFCeCancelaveis() {
    return this.call('listarNFCeCancelaveis', {});
  },

  // aut = { supMatricula, supSenha } quando o backend exigir autorizacao
  async cancelarNFCe(cupomId, justificativa, aut) {
    return this.call('cancelarNFCe',
      Object.assign({ cupomId, justificativa }, aut || {}));
  },

  // 2a via do DANFCe: recarrega o XML autorizado e manda para a impressora
  async reimprimirCupom(cupomId) {
    return this.call('reimprimirCupom', { cupomId });
  },

  // TEF administrativo
  async administracaoTEF() {
    return this.call('administracaoTEF', {});
  },

  async listarTransacoesTEF() {
    return this.call('listarTransacoesTEF', {});
  },

  // aut = { supMatricula, supSenha } quando o backend exigir autorizacao
  async estornarTEF(id, aut) {
    return this.call('estornarTEF', Object.assign({ id }, aut || {}));
  },

  async reimprimirComprovanteTEF(id) {
    return this.call('reimprimirComprovanteTEF', { id });
  },

  // Logotipo da loja (impresso no DANFCe / PDF)
  async obterLogo() {
    return this.call('obterLogo', {});
  },

  // imagem = data URL PNG ("data:image/png;base64,...")
  async salvarLogo(imagem) {
    return this.call('salvarLogo', { imagem });
  },

  async removerLogo() {
    return this.call('removerLogo', {});
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

  // Vendedor
  async buscarVendedor(matricula) {
    return this.call('buscarVendedor', { matricula });
  },

  // Pre-venda
  async listarPreVendas() {
    return this.call('listarPreVendas', {});
  },

  async importarPreVenda(numtrans) {
    return this.call('importarPreVenda', { numtrans });
  },

  // TEF
  async obterConfigTEF() {
    return this.call('obterConfigTEF', {});
  },

  async iniciarPagamentoTEF(dados) {
    return this.call('iniciarPagamentoTEF', dados);
  },

  // Desistir da venda TEF em curso; o desfecho chega pelo tefResultado
  async cancelarTEF() {
    return this.call('cancelarTEF', {});
  },

  async consultarStatusTEF() {
    return this.call('consultarStatusTEF', {});
  },

  // TEF - parametrizacao (aba TEF do modal de documentos fiscais)
  async obterParametrosTEF() {
    return this.call('obterParametrosTEF', {});
  },

  async salvarParametrosTEF(dados) {
    return this.call('salvarParametrosTEF', dados);
  },

  async testarTEF(dados) {
    return this.call('testarTEF', dados);
  },

  // Impressora do cupom (aba Impressora)
  async obterParametrosImpressora() {
    return this.call('obterParametrosImpressora', {});
  },

  async salvarParametrosImpressora(dados) {
    return this.call('salvarParametrosImpressora', dados);
  },

  async testarImpressao() {
    return this.call('testarImpressao', {});
  },

  // Fechar aplicacao (Alt+F4)
  async fecharApp() {
    return this.send('fecharApp', {});
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
