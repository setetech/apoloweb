/* ========================================================
   ApoloWeb - Modulo de Pagamento
   ======================================================== */

// Descricao dos meios de pagamento usados pelo PDV.
// Fallback caso a tabela meios_pagamento nao esteja sincronizada.
const MEIOS_PAGAMENTO = {
  '01': 'Dinheiro',
  '02': 'Cheque',
  '03': 'Cartao',
  '05': 'Cobranca',
  '17': 'PIX',
  '99': 'POS'
};

const Payment = {
  _tefHabilitado: false,
  _bandeirasCarregadas: false,
  _meiosPagto: [],
  _planos: [],
  _pixQrResolve: null,   // Promise pendente do modal de QR Code PIX
  _pixQrValor: 0,
  _pixQrTxid: null,      // txid da cobranca dinamica em andamento (API Pix)
  _pixQrPayload: null,   // payload do QR dinamico (para reimpressao)
  _pixQrPoll: null,      // interval do poll de status no PSP

  // --- PIX pelo TEF ([TEF] pix_qr no apoloweb.ini) ---
  // false = pinpad: a adquirente desenha o QR no visor e o PDV so orienta
  // true  = tela:   o PDV pinta o QR que o gerenciador devolver (tefPixQrCode)
  _tefPixQrTela: false,
  _tefTipoEmCurso: null,   // credito/debito/pix da transacao no ar
  _tefValorEmCurso: 0,     // valor dela, para rotular o QR
  _tefPixQrPayload: null,  // BR Code recebido (reimpressao)
  _tefTimeoutSeg: 120,     // [TEF] timeout do apoloweb.ini
  _tefWatchdog: null,      // destrava a tela se o tefResultado nunca chegar
  _tefAguardando: false,   // spinner do TEF na tela (transacao no ar)
  _tefCancelando: false,   // dialogo/pedido de cancelamento em curso
  _tefInterativo: false,   // [TEF] modo=clisitef: menus/coletas na tela do PDV

  init() {
    this._bindTabs();
    this._bindButtons();
    this._registerKeyboard();
    this._configurarTEF();

    // Recriar os campos de vencimento quando trocar o plano de pagamento
    const selPlano = document.getElementById('pay-cobranca-plano');
    if (selPlano) selPlano.addEventListener('change', () => this._renderParcelasCobranca());

    // Redistribuir os valores das parcelas quando o valor total mudar
    const valorCobranca = document.getElementById('pay-cobranca-valor');
    if (valorCobranca) valorCobranca.addEventListener('input', () => this._atualizarValoresParcelas());
  },

  // Popula o select de plano de pagamento da aba Cobranca a partir da tabela
  // planos_pagamento do SQLite (sincronizada de msapolo_planopagto no Oracle).
  // Enquanto a sync nao rodou a lista vem vazia; tenta de novo na proxima abertura.
  async _carregarPlanos() {
    if (this._planos.length > 0) return;
    try {
      const resp = await Bridge.listarPlanosPagamento();
      if (!resp || !resp.sucesso || !Array.isArray(resp.dados) || resp.dados.length === 0) return;

      this._planos = resp.dados;
      const sel = document.getElementById('pay-cobranca-plano');
      if (!sel) return;
      sel.innerHTML = '';
      resp.dados.forEach(p => {
        const opt = document.createElement('option');
        opt.value = p.codplpag;
        opt.textContent = p.descricao;
        sel.appendChild(opt);
      });
      this._renderParcelasCobranca();
    } catch (e) {
      // Sem cadastro - select permanece vazio
    }
  },

  // ========== PARCELAS DA COBRANCA (campo prazos do plano) ==========

  _planoSelecionado() {
    const sel = document.getElementById('pay-cobranca-plano');
    if (!sel) return null;
    return this._planos.find(p => String(p.codplpag) === sel.value) || null;
  },

  // prazos = dias separados por '/' (ex: '15/30' -> [15, 30]; '0/15/30' ->
  // [0, 15, 30]). Vazio = parcela unica sem prazo definido.
  _prazosDoPlano(plano) {
    if (!plano) return [];
    const raw = String(plano.prazos || '').trim();
    if (!raw) return [];
    return raw.split('/')
      .map(s => parseInt(s.trim(), 10))
      .filter(n => !isNaN(n) && n >= 0);
  },

  _dataMaisDias(dias) {
    const d = new Date();
    d.setDate(d.getDate() + dias);
    const pad = n => String(n).padStart(2, '0');
    return d.getFullYear() + '-' + pad(d.getMonth() + 1) + '-' + pad(d.getDate());
  },

  // Divide o total em parcelas iguais; a dizima fica na ultima
  // (ex: 100,00 em 3x -> 33,33 / 33,33 / 33,34)
  _ratearValor(total, qtde) {
    if (qtde <= 0 || total < 0) return [];
    const base = Math.floor((total / qtde) * 100) / 100;
    const valores = Array(qtde).fill(base);
    valores[qtde - 1] = Math.round((total - base * (qtde - 1)) * 100) / 100;
    return valores;
  },

  _formatarValorInput(valor) {
    return valor.toFixed(2).replace('.', ',');
  },

  // Redistribui os valores das parcelas a partir do valor total digitado
  // (sobrescreve edicoes manuais - o rateio segue o total)
  _atualizarValoresParcelas() {
    const prazos = this._prazosDoPlano(this._planoSelecionado());
    if (prazos.length <= 1) return;
    const total = Utils.parseMoney(document.getElementById('pay-cobranca-valor').value);
    const valores = this._ratearValor(total, prazos.length);
    valores.forEach((v, i) => {
      const inp = document.getElementById('pay-cobranca-valor-' + (i + 1));
      if (inp) inp.value = this._formatarValorInput(v);
    });
  },

  // Monta os campos de valor + vencimento por parcela quando o plano tem mais
  // de um prazo; senao mantem o campo Vencimento padrao (pre-preenchido se o
  // plano tiver prazo unico definido). Valores vem rateados e sao editaveis.
  _renderParcelasCobranca() {
    const cont = document.getElementById('pay-cobranca-parcelas');
    const grpVenc = document.getElementById('grp-cobranca-venc');
    if (!cont || !grpVenc) return;

    const prazos = this._prazosDoPlano(this._planoSelecionado());
    cont.innerHTML = '';

    if (prazos.length <= 1) {
      grpVenc.style.display = '';
      if (prazos.length === 1) {
        document.getElementById('pay-cobranca-venc').value = this._dataMaisDias(prazos[0]);
      }
      return;
    }

    grpVenc.style.display = 'none';
    const total = Utils.parseMoney(document.getElementById('pay-cobranca-valor').value);
    const valores = this._ratearValor(total, prazos.length);

    prazos.forEach((dias, i) => {
      // Valor da parcela (editavel, com mascara de moeda)
      const divValor = document.createElement('div');
      divValor.className = 'input-group';
      const labValor = document.createElement('label');
      labValor.textContent = 'Valor parcela ' + (i + 1);
      const inpValor = document.createElement('input');
      inpValor.type = 'text';
      inpValor.id = 'pay-cobranca-valor-' + (i + 1);
      inpValor.className = 'input-currency';
      inpValor.value = this._formatarValorInput(valores[i]);
      Utils.applyCurrencyMask(inpValor);
      divValor.appendChild(labValor);
      divValor.appendChild(inpValor);
      cont.appendChild(divValor);

      // Vencimento da parcela
      const divVenc = document.createElement('div');
      divVenc.className = 'input-group';
      const labVenc = document.createElement('label');
      labVenc.textContent = 'Venc. parcela ' + (i + 1) + ' (' + dias + ' dias)';
      const inpVenc = document.createElement('input');
      inpVenc.type = 'date';
      inpVenc.id = 'pay-cobranca-venc-' + (i + 1);
      inpVenc.value = this._dataMaisDias(dias);
      divVenc.appendChild(labVenc);
      divVenc.appendChild(inpVenc);
      cont.appendChild(divVenc);
    });
  },

  // Popula o select de meio de pagamento da aba Cobranca a partir da tabela
  // meiopagto do SQLite (sincronizada de msapolo_meiopagto no Oracle).
  // Enquanto a sync nao rodou a lista vem vazia; tenta de novo na proxima abertura.
  async _carregarMeiosPagto() {
    if (this._meiosPagto.length > 0) return;
    try {
      const resp = await Bridge.listarMeioPagto();
      if (!resp || !resp.sucesso || !Array.isArray(resp.dados) || resp.dados.length === 0) return;

      this._meiosPagto = resp.dados;
      const sel = document.getElementById('pay-cobranca-meio');
      if (!sel) return;
      sel.innerHTML = '';
      resp.dados.forEach(m => {
        const opt = document.createElement('option');
        opt.value = m.id;
        opt.textContent = m.descricao;
        sel.appendChild(opt);
      });
    } catch (e) {
      // Sem cadastro - select permanece vazio
    }
  },

  // Popula os selects de bandeira (cartao manual e POS) a partir da tabela
  // bandeiras do SQLite (sincronizada de msapolo_bandeiras no Oracle).
  // Enquanto a sync nao rodou a lista vem vazia; tenta de novo na proxima abertura.
  async _carregarBandeiras() {
    if (this._bandeirasCarregadas) return;
    try {
      const resp = await Bridge.listarBandeiras();
      if (!resp || !resp.sucesso || !Array.isArray(resp.dados) || resp.dados.length === 0) return;

      ['pay-cartao-bandeira', 'pay-pos-bandeira'].forEach(id => {
        const sel = document.getElementById(id);
        if (!sel) return;
        sel.innerHTML = '';
        resp.dados.forEach(b => {
          const opt = document.createElement('option');
          opt.value = b.codbandeira;
          opt.textContent = b.descricao;
          sel.appendChild(opt);
        });
      });
      this._bandeirasCarregadas = true;
    } catch (e) {
      // Sem bandeiras - selects permanecem vazios
    }
  },

  // Aplicar config TEF diretamente (chamado pelo push do Delphi via onMessage)
  aplicarConfigTEF(habilitado, pixQrTela) {
    this._tefHabilitado = !!habilitado;
    if (pixQrTela !== undefined) this._tefPixQrTela = !!pixQrTela;
    const tabCartao = document.querySelector('.pay-tab[data-tab="pay-cartao"]');
    const tabPix = document.querySelector('.pay-tab[data-tab="pay-pix"]');
    const tabTef = document.querySelector('.pay-tab[data-tab="pay-tef"]');
    const hintTef = document.getElementById('pay-hint-tef');

    if (this._tefHabilitado) {
      if (tabCartao) tabCartao.style.display = 'none';
      if (tabPix) tabPix.style.display = 'none';
      if (tabTef) tabTef.style.display = '';
    } else {
      if (tabCartao) tabCartao.style.display = '';
      if (tabPix) tabPix.style.display = '';
      if (tabTef) tabTef.style.display = 'none';
    }
    // Os atalhos F9/F10 so existem com o TEF ligado
    if (hintTef) hintTef.style.display = this._tefHabilitado ? '' : 'none';
  },

  async _configurarTEF() {
    try {
      const resp = await Bridge.obterConfigTEF();
      if (resp && resp.sucesso && resp.dados) {
        this.aplicarConfigTEF(resp.dados.tefHabilitado, resp.dados.tefPixQrTela);
        if (resp.dados.tefTimeout > 0) this._tefTimeoutSeg = resp.dados.tefTimeout;
        this._tefInterativo = !!resp.dados.tefInterativo;
      }
    } catch (e) {
      // Falha silenciosa - TEF sera configurado pelo push do Delphi
    }
  },

  _bindTabs() {
    document.querySelectorAll('#modal-pagamento .pay-tab').forEach(tab => {
      tab.addEventListener('click', () => {
        // Desativar todas
        document.querySelectorAll('#modal-pagamento .pay-tab').forEach(t => t.classList.remove('active'));
        document.querySelectorAll('#modal-pagamento .pay-panel').forEach(p => p.classList.remove('active'));
        // Ativar selecionada
        tab.classList.add('active');
        const panel = document.getElementById(tab.dataset.tab);
        if (panel) panel.classList.add('active');
        // Focar no primeiro input do painel
        if (panel) {
          const input = panel.querySelector('input');
          if (input) setTimeout(() => input.focus(), 100);
        }
      });
    });
  },

  _bindButtons() {
    document.getElementById('btn-pay-add').addEventListener('click', () => this.registrarPagamento());
    document.getElementById('btn-pay-finish').addEventListener('click', () => this.finalizarVenda());
    document.getElementById('btn-pay-cancel').addEventListener('click', () => this.fechar());

    // Modal do QR Code PIX
    document.getElementById('btn-pix-qr-ok').addEventListener('click', () => this._resolverPixQr(true));
    document.getElementById('btn-pix-qr-cancel').addEventListener('click', () => this._resolverPixQr(false));
    document.getElementById('btn-pix-qr-print').addEventListener('click', () => this._imprimirPixQr());

    // Modal do QR Code PIX pelo TEF (pix_qr=tela) - so imprime; quem confirma
    // o pagamento e a adquirente
    document.getElementById('btn-tef-pix-qr-print')
      .addEventListener('click', () => this._imprimirTEFPixQr());

    // Cancelar a transacao TEF em curso (spinner da aba TEF e QR do PIX)
    document.getElementById('btn-tef-cancelar')
      .addEventListener('click', () => this._pedirCancelamentoTEF());
    document.getElementById('btn-tef-pix-qr-cancelar')
      .addEventListener('click', () => this._pedirCancelamentoTEF());
  },

  _registerKeyboard() {
    Keyboard.register('modal_modal-pagamento', {
      'F1': () => this._selectTab('pay-dinheiro'),
      'F2': () => this._selectTab('pay-cheque'),
      'F3': () => this._selectTab(this._tefHabilitado ? 'pay-tef' : 'pay-cartao'),
      'F4': () => { if (!this._tefHabilitado) this._selectTab('pay-pix'); },
      'F5': () => this.finalizarVenda(),
      'F6': () => this._selectTab('pay-pos'),
      'F8': () => this.registrarPagamento(),
      'F9': () => this._atalhoTEF('credito'),
      'F10': () => this._atalhoTEF('debito'),
      'F11': () => this._atalhoTEF('pix'),
      'Enter': () => this.registrarPagamento(),
      'Escape': () => this.fechar()
    });

    // Modal do QR Code PIX (o ESC fecha via Modal.close, que resolve false)
    Keyboard.register('modal_modal-pix-qr', {
      'Enter': () => this._resolverPixQr(true),
      'F8': () => this._resolverPixQr(true),
      'F7': () => this._imprimirPixQr()
    });

    // Modal do QR Code PIX pelo TEF: nao ha o que confirmar aqui, a transacao
    // esta em curso no gerenciador. Reimpressao ou cancelamento (o ESC chega
    // aqui pelo data-esc-bloqueado, em vez de fechar o modal).
    Keyboard.register('modal_modal-tef-pix-qr', {
      'F7': () => this._imprimirTEFPixQr(),
      'Escape': () => this._pedirCancelamentoTEF()
    });
  },

  // ========== QR CODE PIX ==========

  // Meio de pagamento da aba Cobranca que representa PIX (ex: PIX MANUAL,
  // codcob PIXM no msapolo_meiopagto)
  _ehMeioPix(meio) {
    if (!meio) return false;
    const cod = String(meio.codcob || '').trim().toUpperCase();
    const desc = String(meio.descricao || '').toUpperCase();
    return cod.indexOf('PIX') === 0 || desc.indexOf('PIX') !== -1;
  },

  _renderPixQr(payload, valor, chaveTexto) {
    const cont = document.getElementById('pix-qr-code');
    cont.innerHTML = new QRCodeGen({
      content: payload,
      padding: 2, width: 260, height: 260,
      ecl: 'M', join: true, container: 'svg-viewbox', xmlDeclaration: false
    }).svg();
    document.getElementById('pix-qr-valor').textContent = Utils.formatCurrency(valor);
    document.getElementById('pix-qr-chave').textContent = chaveTexto || '';
  },

  _setPixStatus(texto) {
    const el = document.getElementById('pix-qr-status');
    if (!el) return;
    el.textContent = texto || '';
    el.classList.toggle('hidden', !texto);
  },

  // Mostra o QR Code e aguarda o pagamento. Com a API Pix configurada
  // (pixcd_config, sincronizada da msapolo_pixcd) a cobranca e dinamica e a
  // confirmacao do recebimento e AUTOMATICA (poll no PSP a cada 3s); sem
  // configuracao cai no QR estatico com confirmacao manual do operador.
  // Retorna false (cancelado), true, ou {ok:true, e2eid} (pago via PSP).
  async _confirmarPixQR(valor) {
    // 1) Cobranca dinamica (API Pix via ACBrPIXCD)
    let din = null;
    try {
      din = await Bridge.iniciarCobrancaPix(valor);
    } catch (e) {
      din = null;
    }
    if (din && din.sucesso && din.dados && din.dados.payload) {
      try {
        this._renderPixQr(din.dados.payload, valor, '');
      } catch (e) {
        Toast.warning('Falha ao gerar o QR Code PIX');
        return true;
      }
      this._pixQrValor = valor;
      this._pixQrTxid = din.dados.txid;
      this._pixQrPayload = din.dados.payload;
      this._setPixStatus('Aguardando pagamento... a confirmacao e automatica');
      this._iniciarPollPix(din.dados.txid);
      return new Promise((resolve) => {
        this._pixQrResolve = resolve;
        Modal.open('modal-pix-qr');
      });
    }
    // PixCD configurado mas indisponivel (credencial/rede): avisa e segue
    // no estatico; "nao configurada" e o caso normal de quem nao usa a API
    if (din && !din.sucesso && din.mensagem && !/nao configurada/i.test(din.mensagem)) {
      Toast.warning('PIX dinamico indisponivel: ' + din.mensagem);
    }

    // 2) Fallback: QR estatico + confirmacao manual
    let resp;
    try {
      resp = await Bridge.obterPixQRCode(valor);
    } catch (e) {
      return true;
    }
    if (!resp || !resp.sucesso || !resp.dados || !resp.dados.payload) {
      if (resp && resp.mensagem) Toast.warning(resp.mensagem);
      return true;
    }
    try {
      this._renderPixQr(resp.dados.payload, valor, 'Chave: ' + resp.dados.chave);
    } catch (e) {
      Toast.warning('Falha ao gerar o QR Code PIX');
      return true;
    }
    this._pixQrValor = valor;
    this._pixQrTxid = null;
    this._pixQrPayload = null;
    this._setPixStatus('');
    return new Promise((resolve) => {
      this._pixQrResolve = resolve;
      Modal.open('modal-pix-qr');
    });
  },

  // Poll da cobranca dinamica: consulta o PSP a cada 3s ate o pagamento
  // cair (CONCLUIDA), a cobranca sumir (REMOVIDA_*) ou o modal fechar
  _iniciarPollPix(txid) {
    this._pararPollPix(false);
    let consultando = false;
    this._pixQrPoll = setInterval(async () => {
      if (!this._pixQrResolve) { this._pararPollPix(false); return; }
      if (consultando) return;   // consulta anterior ainda em curso
      consultando = true;
      try {
        const resp = await Bridge.consultarCobrancaPix(txid);
        if (resp && resp.sucesso && resp.dados && this._pixQrResolve) {
          if (resp.dados.pago) {
            Toast.success('Pagamento PIX confirmado!');
            this._resolverPixQr({ ok: true, e2eid: resp.dados.e2eid || '' });
            return;
          }
          if (/^REMOVIDA/.test(resp.dados.status || '')) {
            Toast.warning('Cobranca PIX removida no PSP');
            this._resolverPixQr(false);
            return;
          }
        }
      } catch (e) {
        // erro pontual de rede: tenta de novo no proximo tick
      } finally {
        consultando = false;
      }
    }, 3000);
  },

  // So limpa o txid quando cancela: _iniciarPollPix chama _pararPollPix(false)
  // logo APOS o txid ser setado, e zerar aqui perderia a cobranca em curso
  _pararPollPix(cancelarCobranca) {
    if (this._pixQrPoll) {
      clearInterval(this._pixQrPoll);
      this._pixQrPoll = null;
    }
    if (cancelarCobranca && this._pixQrTxid) {
      // fire-and-forget: nao atrasar o fechamento do modal
      Bridge.cancelarCobrancaPix(this._pixQrTxid).catch(() => {});
    }
    if (cancelarCobranca) this._pixQrTxid = null;
  },

  // Captura e limpa o resolver ANTES do Modal.close (que tambem resolve com
  // false como fallback do ESC/X) - mesmo cuidado do Dialog.
  _resolverPixQr(confirmado) {
    const resolver = this._pixQrResolve;
    this._pixQrResolve = null;
    this._pararPollPix(!confirmado);
    this._pixQrTxid = null;
    Modal.close('modal-pix-qr');
    if (resolver) resolver(confirmado);
  },

  // Chamado pelo Modal.close quando o modal fecha direto por ESC/X
  // (keyboard.js) - cancela a cobranca dinamica pendente e resolve false
  _onPixQrFechado() {
    const resolver = this._pixQrResolve;
    if (!resolver) return;   // fechamento veio de _resolverPixQr
    this._pixQrResolve = null;
    this._pararPollPix(true);
    resolver(false);
  },

  async _imprimirPixQr() {
    const resp = await Bridge.imprimirPixQRCode(this._pixQrValor, this._pixQrPayload);
    if (resp && resp.sucesso) Toast.success('QR Code enviado para a impressora');
  },

  _selectTab(tabId) {
    const tab = document.querySelector(`#modal-pagamento .pay-tab[data-tab="${tabId}"]`);
    if (tab) tab.click();
  },

  // Atalho de uma tecla para o TEF: abre uma caixa de dialogo com o valor
  // restante ja preenchido. O operador so da Enter - ou digita outro valor e
  // da Enter - e o pinpad e acionado na hora, sem passar pela aba.
  async _atalhoTEF(tipo) {
    if (!this._tefHabilitado) return;

    // Transacao em curso: _showTEFAguardando desabilita os botoes enquanto o
    // pinpad nao responde. Nao deixar empilhar outra por cima.
    const btnAdd = document.getElementById('btn-pay-add');
    if (btnAdd && btnAdd.disabled) return;

    const LABELS = { debito: 'Debito', pix: 'PIX', credito: 'Credito' };
    const label = LABELS[tipo] || 'Credito';
    const restanteEl = document.getElementById('pay-restante');
    const restante = restanteEl ? Utils.parseMoney(restanteEl.textContent) : 0;
    if (restante <= 0) {
      Toast.warning('Nao ha valor restante a pagar');
      return;
    }

    // Mesmo formato que a mascara monetaria produz (sem separador de milhar).
    const informado = await Dialog.prompt(
      'TEF ' + label,
      tipo === 'pix'
        ? 'Confirme o valor a cobrar no PIX'
        : 'Confirme o valor a passar no pinpad',
      'Valor (R$)',
      restante.toFixed(2).replace('.', ',')
    );
    if (informado === null) return;   // ESC ou Cancelar

    const valor = Utils.parseMoney(informado);
    if (!valor || valor <= 0) {
      Toast.warning('Informe um valor valido');
      return;
    }

    // Deixar a aba TEF ativa e coerente com o que foi disparado: e' nela que
    // fica o spinner "Aguardando resposta do TEF" e e' para la que o operador
    // olha se precisar repetir a transacao.
    this._selectTab('pay-tef');
    document.getElementById('pay-tef-tipo').value = tipo;
    document.getElementById('pay-tef-parcelas').value = 1;
    document.getElementById('pay-tef-valor').value = valor.toFixed(2).replace('.', ',');

    // O atalho e sempre a vista; para parcelar, o operador usa a aba (F3).
    await this._dispararTEF(valor, tipo, '01');
  },

  async open() {
    // Reconfigurar TEF (pode ter mudado apos config ou falhado no init)
    await this._configurarTEF();
    // Carregar bandeiras (cartao/POS), meios e planos de pagamento (cobranca)
    await this._carregarBandeiras();
    await this._carregarMeiosPagto();
    await this._carregarPlanos();
    // Recalcular vencimentos das parcelas com a data de hoje
    this._renderParcelasCobranca();
    // Carregar resumo
    await this.atualizarResumo();
    Modal.open('modal-pagamento');

    // Focar no input de dinheiro
    this._selectTab('pay-dinheiro');
    setTimeout(() => {
      const input = document.getElementById('pay-dinheiro-valor');
      if (input) { input.value = ''; input.focus(); }
    }, 200);
  },

  fechar() {
    // Com o TEF no ar, fechar a tela deixava a transacao correndo escondida:
    // ESC e o botao Cancelar passam a oferecer o cancelamento do TEF
    if (this._tefAguardando) {
      this._pedirCancelamentoTEF();
      return;
    }
    Modal.close('modal-pagamento');
  },

  async atualizarResumo() {
    const resp = await Bridge.obterResumoPagamento();
    if (!resp || !resp.sucesso) return;

    const d = resp.dados;
    document.getElementById('pay-total').textContent = Utils.formatCurrency(d.total);
    document.getElementById('pay-pago').textContent = Utils.formatCurrency(d.totalPago);
    document.getElementById('pay-restante').textContent = Utils.formatCurrency(d.restante);

    // Atualizar sidebar do POS tambem
    document.getElementById('pos-total-pago').textContent = Utils.formatMoney(d.totalPago);
    document.getElementById('pos-restante').textContent = Utils.formatMoney(d.restante);
    document.getElementById('pos-troco').textContent = Utils.formatCurrency(d.troco);

    // Lista de pagamentos
    const listEl = document.getElementById('pay-list');
    listEl.innerHTML = '';
    if (d.pagamentos) {
      d.pagamentos.forEach(p => {
        const desc = p.descricao || MEIOS_PAGAMENTO[p.codcob] || ('Cod. ' + p.codcob);
        const item = document.createElement('div');
        item.className = 'pay-list-item';
        item.innerHTML = `
          <span class="pay-list-desc"><span class="pay-list-cod">${p.codcob}</span>${desc}</span>
          <span class="pay-val">${Utils.formatCurrency(p.valor)}</span>
          <button class="pay-list-remove" data-id="${p.id}" title="Remover">&times;</button>
        `;
        item.querySelector('.pay-list-remove').addEventListener('click', async () => {
          await Bridge.removerPagamento(p.id);
          this.atualizarResumo();
        });
        listEl.appendChild(item);
      });
    }
  },

  async registrarPagamento() {
    // Determinar qual tab esta ativa
    const activePanel = document.querySelector('#modal-pagamento .pay-panel.active');
    if (!activePanel) return;

    let dados = {};
    let pagamentoPix = false;
    const panelId = activePanel.id;

    switch (panelId) {
      case 'pay-dinheiro':
        dados = {
          codcob: '01',
          valor: Utils.parseMoney(document.getElementById('pay-dinheiro-valor').value)
        };
        break;

      case 'pay-cheque':
        dados = {
          codcob: '02',
          valor: Utils.parseMoney(document.getElementById('pay-cheque-valor').value),
          numbanco: parseInt(document.getElementById('pay-cheque-banco').value) || 0,
          numagencia: document.getElementById('pay-cheque-agencia').value,
          numcontacorrente: document.getElementById('pay-cheque-conta').value,
          numcheque: document.getElementById('pay-cheque-num').value,
          cpf_cnpj_cheque: document.getElementById('pay-cheque-cpf').value,
          numcmc7: document.getElementById('pay-cheque-cmc7').value,
          dtpredatado: document.getElementById('pay-cheque-dt').value
        };
        break;

      case 'pay-cartao':
        dados = {
          codcob: '03',
          valor: Utils.parseMoney(document.getElementById('pay-cartao-valor').value),
          codtipotransacao: document.getElementById('pay-cartao-tipo').value === 'credito' ? 1 : 2,
          codbandeira: parseInt(document.getElementById('pay-cartao-bandeira').value) || 0,
          qtdeparcela: parseInt(document.getElementById('pay-cartao-parcelas').value) || 1,
          nsu: document.getElementById('pay-cartao-nsu').value,
          codautorizacao: document.getElementById('pay-cartao-aut').value
        };
        break;

      case 'pay-pix':
        dados = {
          codcob: '17', // PIX
          valor: Utils.parseMoney(document.getElementById('pay-pix-valor').value),
          nsu: document.getElementById('pay-pix-id').value
        };
        pagamentoPix = true;
        break;

      case 'pay-tef':
        // TEF - fluxo especial async
        await this._iniciarPagamentoTEF();
        return;

      case 'pay-cobranca': {
        const selMeio = document.getElementById('pay-cobranca-meio');
        const meio = this._meiosPagto.find(m => String(m.id) === selMeio.value);
        const documento = (document.getElementById('pay-cobranca-doc').value || '').trim();
        const prazos = this._prazosDoPlano(this._planoSelecionado());
        const multiParcela = prazos.length > 1;

        const valorTotal = Utils.parseMoney(document.getElementById('pay-cobranca-valor').value);
        let dtvenc = document.getElementById('pay-cobranca-venc').value;
        let parcelas = [];

        if (multiParcela) {
          let somaParcelas = 0;
          for (let i = 1; i <= prazos.length; i++) {
            const inpVenc = document.getElementById('pay-cobranca-venc-' + i);
            const venc = inpVenc ? inpVenc.value : '';
            if (!venc) {
              Toast.warning('Informe o vencimento da parcela ' + i);
              if (inpVenc) inpVenc.focus();
              return;
            }
            const inpValor = document.getElementById('pay-cobranca-valor-' + i);
            const valorParcela = Utils.parseMoney(inpValor ? inpValor.value : '');
            if (!valorParcela || valorParcela <= 0) {
              Toast.warning('Informe o valor da parcela ' + i);
              if (inpValor) inpValor.focus();
              return;
            }
            somaParcelas += valorParcela;
            parcelas.push({ dtvenc: venc, valor: valorParcela });
          }
          somaParcelas = Math.round(somaParcelas * 100) / 100;
          if (Math.abs(somaParcelas - valorTotal) > 0.005) {
            Toast.warning('A soma das parcelas (' + Utils.formatCurrency(somaParcelas) +
              ') difere do valor do pagamento (' + Utils.formatCurrency(valorTotal) + ')');
            return;
          }
          dtvenc = parcelas[0].dtvenc;
        }

        if (this._meiosPagto.length > 0 && !meio) {
          Toast.warning('Selecione o meio de pagamento');
          return;
        }
        if (meio && meio.obg_dtvenc === 'S' && !dtvenc) {
          Toast.warning('Informe a data de vencimento');
          return;
        }
        if (meio && meio.obg_documento === 'S' && !documento) {
          Toast.warning('Informe o numero do documento');
          return;
        }

        pagamentoPix = this._ehMeioPix(meio);
        dados = {
          // codcob do cadastro do retaguarda (msapolo_meiopagto);
          // '05' e o fallback legado quando nao ha cadastro sincronizado
          codcob: meio ? meio.codcob : '05',
          valor: valorTotal,
          codplpag: parseInt(document.getElementById('pay-cobranca-plano').value) || 0,
          dtvenc: dtvenc,
          numcheque: documento
        };
        if (multiParcela) dados._parcelas = parcelas;
        break;
      }

      case 'pay-pos':
        dados = {
          codcob: '99',
          valor: Utils.parseMoney(document.getElementById('pay-pos-valor').value),
          codtipotransacao: document.getElementById('pay-pos-tipo').value === 'credito' ? 1 : 2,
          codbandeira: parseInt(document.getElementById('pay-pos-bandeira').value) || 0,
          qtdeparcela: parseInt(document.getElementById('pay-pos-parcelas').value) || 1,
          nsu: document.getElementById('pay-pos-nsu').value,
          codautorizacao: document.getElementById('pay-pos-aut').value
        };
        break;
    }

    if (!dados.valor || dados.valor <= 0) {
      Toast.warning('Informe um valor valido');
      return;
    }

    if (!this._validarPanel(panelId)) return;

    // PIX: apresentar o QR Code (chave da filial + valor) e so registrar o
    // pagamento depois da confirmacao - automatica (API Pix) ou do operador
    if (pagamentoPix) {
      const confirmado = await this._confirmarPixQR(dados.valor);
      if (!confirmado) return;
      // Pagamento confirmado pelo PSP: endToEndId identifica a transacao
      if (confirmado.e2eid && !dados.nsu) dados.nsu = confirmado.e2eid;
    }

    let resp;
    if (dados._parcelas) {
      // Cobranca parcelada: uma linha de pagamento por parcela, com o valor
      // e vencimento informados na tela
      const parcelas = dados._parcelas;
      delete dados._parcelas;

      for (let i = 0; i < parcelas.length; i++) {
        resp = await Bridge.registrarPagamento(Object.assign({}, dados, {
          valor: parcelas[i].valor,
          dtvenc: parcelas[i].dtvenc,
          numparcela: i + 1,
          qtdeparcela: parcelas.length
        }));
        if (!resp || !resp.sucesso) break;
      }
    } else {
      resp = await Bridge.registrarPagamento(dados);
    }

    if (resp && resp.sucesso) {
      Toast.success('Pagamento registrado');
      this._limparInputsAtivos();
      if (panelId === 'pay-cobranca') this._renderParcelasCobranca();
      await this.atualizarResumo();

      // Auto-finalizar quando valor pago >= total da venda
      const restanteEl = document.getElementById('pay-restante');
      if (restanteEl) {
        const restante = Utils.parseMoney(restanteEl.textContent);
        if (restante <= 0) {
          this.finalizarVenda();
        }
      }
    }
  },

  // ========== VALIDACAO ==========

  // Retorna false (e avisa/foca o campo) quando falta informacao obrigatoria
  _validarPanel(panelId) {
    switch (panelId) {
      case 'pay-cheque': return this._validarCheque();
      default: return true;
    }
  },

  _obrigatorio(id, mensagem) {
    const el = document.getElementById(id);
    if (!el || el.value.trim() === '') {
      Toast.warning(mensagem);
      if (el) el.focus();
      return false;
    }
    return true;
  },

  _validarCheque() {
    if (!this._obrigatorio('pay-cheque-banco', 'Informe o banco do cheque')) return false;
    if (!this._obrigatorio('pay-cheque-agencia', 'Informe a agencia do cheque')) return false;
    if (!this._obrigatorio('pay-cheque-conta', 'Informe a conta corrente do cheque')) return false;
    if (!this._obrigatorio('pay-cheque-num', 'Informe o numero do cheque')) return false;

    const banco = document.getElementById('pay-cheque-banco');
    if (!/^\d+$/.test(banco.value.trim()) || parseInt(banco.value, 10) <= 0) {
      Toast.warning('Banco invalido - informe o codigo numerico');
      banco.focus();
      return false;
    }

    // CPF/CNPJ eh opcional, mas se informado precisa ter tamanho valido
    const cpf = document.getElementById('pay-cheque-cpf');
    const cpfDigitos = cpf.value.replace(/\D/g, '');
    if (cpfDigitos !== '' && cpfDigitos.length !== 11 && cpfDigitos.length !== 14) {
      Toast.warning('CPF/CNPJ invalido');
      cpf.focus();
      return false;
    }

    return true;
  },

  // ========== TEF ==========

  async _iniciarPagamentoTEF() {
    const valor = Utils.parseMoney(document.getElementById('pay-tef-valor').value);
    const tipoTransacao = document.getElementById('pay-tef-tipo').value;
    const parcelas = String(document.getElementById('pay-tef-parcelas').value || 1).padStart(2, '0');

    if (!valor || valor <= 0) {
      Toast.warning('Informe um valor valido');
      return;
    }

    await this._dispararTEF(valor, tipoTransacao, parcelas);
  },

  // Envio propriamente dito - compartilhado pela aba (F3 + Enter/F8) e pelos
  // atalhos F9/F10.
  async _dispararTEF(valor, tipoTransacao, parcelas) {
    // Enter/F8 na aba TEF com a transacao no ar: nao disparar outra por cima
    // (e o erro do Delphi nao pode esconder o spinner da que esta correndo)
    if (this._tefAguardando) return;

    // Guardados para rotular o QR e decidir o texto da espera: o push do
    // Delphi so traz o payload, nao repete tipo nem valor
    this._tefTipoEmCurso = tipoTransacao;
    this._tefValorEmCurso = valor;
    this._tefPixQrPayload = null;

    // Mostrar spinner de aguardo
    this._showTEFAguardando(true);

    try {
      const resp = await Bridge.iniciarPagamentoTEF({
        valor: valor,
        tipoTransacao: tipoTransacao,
        parcelas: parcelas
      });

      // O bridge retorna imediatamente com "Processando..."
      // O resultado real vem via onMessage('tefResultado')
      if (!resp || !resp.sucesso) {
        this._showTEFAguardando(false);
        Toast.error(resp ? resp.mensagem : 'Erro ao iniciar TEF');
      }
    } catch (e) {
      this._showTEFAguardando(false);
      Toast.error('Erro de comunicacao com TEF');
    }
  },

  // ---------- QR Code do PIX pelo TEF ----------

  // SOLUCAO pix_qr=pinpad: o PDV nao tem o QR, entao a tela de espera e' o
  // unico lugar onde da para orientar o cliente. Sem isso o operador le
  // "insira ou aproxime o cartao" no meio de um PIX e ninguem olha o pinpad.
  _textoAguardandoTEF() {
    const ehPix = this._tefTipoEmCurso === 'pix';
    if (!ehPix) {
      return {
        titulo: 'Aguardando resposta do TEF...',
        sub: 'Insira ou aproxime o cartao na maquininha'
      };
    }
    return {
      titulo: 'Aguardando o pagamento PIX...',
      sub: this._tefPixQrTela
        ? 'O QR Code aparece aqui assim que a adquirente responder'
        : 'Peca ao cliente para ler o QR Code no visor do pinpad'
    };
  },

  _aplicarTextoAguardandoTEF() {
    const texto = this._textoAguardandoTEF();
    const titulo = document.getElementById('tef-aguardando-titulo');
    const sub = document.getElementById('tef-aguardando-sub');
    if (titulo) titulo.textContent = texto.titulo;
    if (sub) sub.textContent = texto.sub;
  },

  // SOLUCAO pix_qr=tela: chega pelo push tefPixQrCode, disparado assim que o
  // gerenciador devolve o BR Code - de preferencia antes do resultado, com a
  // transacao ainda no ar. Nao ha botao de confirmar: quem aprova e a
  // adquirente, e o modal fecha sozinho no _onTEFResultado.
  _onTEFPixQrCode(data) {
    if (!data || !data.payload) return;

    // Chegou com pix_qr=pinpad (ou fora de uma transacao): so registra
    if (!this._tefPixQrTela) {
      console.log('QR Code PIX recebido do TEF, mas pix_qr=pinpad');
      return;
    }

    this._tefPixQrPayload = data.payload;

    const cont = document.getElementById('tef-pix-qr-code');
    if (cont) {
      cont.innerHTML = new QRCodeGen({
        content: data.payload,
        width: 260,
        height: 260,
        padding: 2,
        color: '#000000',
        background: '#ffffff',
        ecl: 'M'
      }).svg();
    }

    const valorEl = document.getElementById('tef-pix-qr-valor');
    if (valorEl) valorEl.textContent = Utils.formatCurrency(this._tefValorEmCurso);

    Modal.open('modal-tef-pix-qr');
  },

  _fecharTEFPixQr() {
    if (Modal.isOpen('modal-tef-pix-qr')) Modal.close('modal-tef-pix-qr');
  },

  async _imprimirTEFPixQr() {
    if (!this._tefPixQrPayload) {
      Toast.warning('Nao ha QR Code para imprimir');
      return;
    }
    const resp = await Bridge.imprimirPixQRCode(
      this._tefValorEmCurso, this._tefPixQrPayload);
    if (resp && resp.sucesso) Toast.success('QR Code enviado para a impressora');
  },

  _showTEFAguardando(show) {
    if (show) this._aplicarTextoAguardandoTEF();
    this._tefAguardando = show;

    // ESC no pagamento com o TEF no ar vai para o handler 'Escape' (fechar ->
    // pedir cancelamento) em vez de fechar o modal direto
    const modalPag = document.getElementById('modal-pagamento');
    if (modalPag) {
      if (show) modalPag.dataset.escBloqueado = '1';
      else delete modalPag.dataset.escBloqueado;
    }

    // Rede de seguranca: o Delphi desiste da transacao no [TEF] timeout e
    // SEMPRE manda o tefResultado. Se ele nao chegar bem depois disso, algo
    // se perdeu no caminho - destrava a tela em vez de deixar o QR do PIX
    // (que nao fecha no ESC) preso para sempre.
    clearTimeout(this._tefWatchdog);
    this._tefWatchdog = null;
    if (show) this._armarWatchdogTEF();

    const indicator = document.getElementById('tef-aguardando');
    if (indicator) {
      indicator.classList.toggle('hidden', !show);
    }
    // Desabilitar/habilitar botoes enquanto aguarda
    const btnAdd = document.getElementById('btn-pay-add');
    const btnFinish = document.getElementById('btn-pay-finish');
    if (btnAdd) btnAdd.disabled = show;
    if (btnFinish) btnFinish.disabled = show;
  },

  _armarWatchdogTEF() {
    clearTimeout(this._tefWatchdog);
    this._tefWatchdog = setTimeout(() => {
      this._tefWatchdog = null;
      this._showTEFAguardando(false);
      this._fecharTEFPixQr();
      if (typeof TEFInterativo !== 'undefined') TEFInterativo.fechar();
      this._tefTipoEmCurso = null;
      Toast.error('Sem resposta do TEF. Confira no gerenciador/pinpad se o ' +
        'pagamento foi aprovado antes de repetir.');
      this.atualizarResumo();
    }, (this._tefTimeoutSeg + 60) * 1000);
  },

  // modo=clisitef: menus e coletas podem somar mais que o [TEF] timeout;
  // cada evento da CliSiTef rearma o relogio
  _reiniciarWatchdogTEF() {
    if (this._tefAguardando) this._armarWatchdogTEF();
  },

  // Operador desistiu da transacao (botao ou ESC). O Delphi retira a venda se
  // o gerenciador ainda nao a leu; se o pinpad ja estava com ela, nao ha como
  // aborta-la daqui - o PDV segue esperando o desfecho por tras e desfaz uma
  // aprovacao tardia. Em qualquer caso a tela e' liberada na hora para o
  // operador receber de outra forma.
  async _pedirCancelamentoTEF() {
    if (!this._tefAguardando || this._tefCancelando) return;
    this._tefCancelando = true;
    try {
      const ok = await Dialog.confirm('Cancelar TEF',
        'Cancelar a transacao TEF em andamento? Se o cliente ja tiver pago ' +
        'no pinpad, a transacao sera desfeita automaticamente.');
      // O resultado pode ter chegado com o dialogo aberto
      if (!ok || !this._tefAguardando) return;

      const resp = await Bridge.cancelarTEF();
      if (!resp || !resp.sucesso) {
        Toast.warning(resp && resp.mensagem ? resp.mensagem : 'Falha ao cancelar o TEF');
        return;
      }

      this._showTEFAguardando(false);
      this._fecharTEFPixQr();
      this._tefTipoEmCurso = null;
      Toast.warning('TEF cancelado no PDV. Se o pinpad ainda estiver ' +
        'aguardando, cancele nele tambem.');
      this.atualizarResumo();
    } catch (e) {
      Toast.error('Erro ao cancelar o TEF');
    } finally {
      this._tefCancelando = false;
    }
  },

  _onTEFResultado(data) {
    this._showTEFAguardando(false);
    // A transacao acabou (aprovada, recusada ou por excecao no Delphi): o QR
    // do PIX nao vale mais nada na tela
    this._fecharTEFPixQr();
    this._tefTipoEmCurso = null;

    // Desfecho de uma transacao que o operador ja cancelou: a tela foi
    // liberada no pedido e a venda pode ter seguido com outro meio - nada de
    // registrar ou auto-finalizar aqui
    if (data.canceladoOperador) {
      if (data.desfeita) Toast.error(data.erro);
      else Toast.info('Transacao TEF cancelada');
      this.atualizarResumo();
      return;
    }

    if (data.sucesso) {
      let msg = 'TEF aprovado!';
      if (data.nsu) msg += ' NSU: ' + data.nsu;
      if (data.bandeira) msg += ' (' + data.bandeira + ')';
      Toast.success(msg);

      this._limparInputsAtivos();
      this.atualizarResumo();

      // Auto-finalizar se totalmente pago
      setTimeout(() => {
        const restanteEl = document.getElementById('pay-restante');
        if (restanteEl) {
          const restante = Utils.parseMoney(restanteEl.textContent);
          if (restante <= 0) {
            this.finalizarVenda();
          }
        }
      }, 500);
    } else {
      Toast.error('TEF recusado: ' + (data.erro || 'Erro desconhecido'));
    }
  },

  // ========== FIM TEF ==========

  async finalizarVenda() {
    let resp;
    try {
      resp = await Bridge.finalizarVenda();
    } catch (err) {
      // Timeout da Bridge: o Delphi pode ter fechado a venda por conta
      // propria (upload lento para o Oracle) enquanto o front ficou sem a
      // resposta. Nao fica preso no modal: pergunta ao Delphi em que estado
      // o caixa esta' e segue por ali. Se a venda fechou sem nota, ela
      // aparece em Documentos Fiscais com o botao Emitir NFCe.
      Toast.error('Sem resposta do fechamento: ' + err.message);
      const estado = await Bridge.obterEstadoCaixa();
      if (estado && estado.sucesso && estado.dados.cupomAtualId === 0) {
        this.fechar();
        Toast.warning('Venda fechada sem NFCe - emita em Documentos Fiscais');
        POS.limparVenda();
      }
      return;
    }
    if (resp && resp.sucesso) {
      this.fechar();
      POS.finalizarVendaCompleta(resp.dados);
    }
  },

  _limparInputsAtivos() {
    const activePanel = document.querySelector('#modal-pagamento .pay-panel.active');
    if (activePanel) {
      activePanel.querySelectorAll('input').forEach(input => {
        input.value = input.classList.contains('input-currency') ? '' : '';
      });
      const firstInput = activePanel.querySelector('input');
      if (firstInput) firstInput.focus();
    }
  }
};
