/* ========================================================
   ApoloWeb - Modulo PDV (Frente de Caixa)
   ======================================================== */

const POS = {
  cupomId: 0,
  numCupom: 0,
  estado: 'livre', // livre, registrando, pagamento
  itens: [],
  _qtdePendente: 1,

  init() {
    this._bindEvents();
    this._startClock();
    this._registerKeyboard();
  },

  _bindEvents() {
    // Input de barcode
    const barcodeInput = document.getElementById('barcode-input');

    // Capturar "*" via keydown (teclado normal e numpad)
    barcodeInput.addEventListener('keydown', (e) => {
      if (e.key === '*' || e.key === 'Multiply') {
        e.preventDefault();
        e.stopPropagation();
        this._processarQuantidade(barcodeInput);
        return;
      }
      if (e.key === 'Enter' && barcodeInput.value.trim()) {
        e.preventDefault();
        this.processarCodigo(barcodeInput.value.trim());
      }
    });

    // Fallback: se o "*" passar para o valor do input (WebView2/teclado ABNT2)
    barcodeInput.addEventListener('input', () => {
      const val = barcodeInput.value;
      if (val.includes('*')) {
        const partes = val.split('*');
        const qtdStr = partes[0].trim();
        const restante = partes.slice(1).join('').trim();

        if (qtdStr) {
          const qtde = Utils.parseMoney(qtdStr);
          if (qtde > 0) {
            this._setQuantidadePendente(qtde);
          }
        }
        barcodeInput.value = restante;
      }
    });

    // Botao de busca
    document.getElementById('btn-search-product').addEventListener('click', () => {
      Products.open();
    });

    // Vendedor - buscar nome ao sair do campo
    const vendedorInput = document.getElementById('input-vendedor');
    vendedorInput.addEventListener('change', async () => {
      const nomeEl = document.getElementById('vendedor-nome');
      const mat = parseInt(vendedorInput.value) || 0;
      if (mat > 0) {
        const resp = await Bridge.buscarVendedor(mat);
        if (resp && resp.sucesso) {
          nomeEl.textContent = resp.dados.nome;
        } else {
          nomeEl.textContent = '';
        }
      } else {
        nomeEl.textContent = '';
      }
    });
  },

  _processarQuantidade(input) {
    const valor = input.value.trim();
    if (!valor) {
      // Asterisco sem valor: resetar quantidade para 1
      this._setQuantidadePendente(1);
      return;
    }

    const qtde = Utils.parseMoney(valor);
    if (qtde <= 0) {
      Toast.error('Quantidade invalida');
      input.value = '';
      return;
    }

    this._setQuantidadePendente(qtde);
    input.value = '';
    input.focus();
  },

  _setQuantidadePendente(qtde) {
    this._qtdePendente = qtde;
    const panel = document.getElementById('quick-qty-panel');
    const display = document.getElementById('quick-qty-display');

    if (qtde !== 1) {
      display.textContent = Utils.formatMoney(qtde);
      panel.style.display = 'flex';
      Toast.info('Quantidade: ' + Utils.formatMoney(qtde));
    } else {
      panel.style.display = 'none';
    }
  },

  _registerKeyboard() {
    Keyboard.register('global', {
      'F1': () => Products.open(),
      'F2': () => Customers.open(),
      'F3': () => this.solicitarDesconto(),
      'F4': () => this.abrirPagamento(),
      'F6': () => this.cancelarItem(),
      'F7': () => this.abrirPreVenda(),
      'F8': () => this.solicitarSangria(),
      'F9': () => this.solicitarSuprimento(),
      'F10': () => NFCePanel.open(),
      'F11': () => this.solicitarFechamento(),
      'F12': () => this.cancelarVenda(),
      'Escape': () => this.voltarBarcode()
    });
  },

  _startClock() {
    const updateClock = () => {
      document.getElementById('pos-clock').textContent = Utils.getCurrentTime();
    };
    updateClock();
    setInterval(updateClock, 1000);
  },

  // Configurar info do header
  setHeaderInfo(numCaixa, operador) {
    document.getElementById('pos-caixa').textContent = 'Caixa: ' + (numCaixa || '---');
    document.getElementById('pos-operador').textContent = 'Operador: ' + (operador || '---');
  },

  setEstado(estado) {
    this.estado = estado;
    const badge = document.getElementById('pos-cupom-info');
    switch (estado) {
      case 'registrando':
        badge.textContent = 'Cupom #' + this.numCupom + ' - Registrando';
        break;
      case 'pagamento':
        badge.textContent = 'Cupom #' + this.numCupom + ' - Pagamento';
        document.getElementById('payment-summary').classList.remove('hidden');
        break;
      default:
        badge.textContent = 'Caixa Livre';
        document.getElementById('payment-summary').classList.add('hidden');
    }
  },

  // ===== PROCESSAR CODIGO =====
  async processarCodigo(codigo) {
    const barcodeInput = document.getElementById('barcode-input');
    barcodeInput.value = '';

    if (!codigo) return;

    // Se caixa esta livre, iniciar venda automaticamente
    if (this.estado === 'livre') {
      const resp = await Bridge.iniciarVenda();
      if (!resp || !resp.sucesso) return;

      this.cupomId = resp.dados.cupomId;
      this.numCupom = resp.dados.numCupom;
      this.setEstado('registrando');
      Toast.info('Venda #' + this.numCupom + ' iniciada');
    }

    // Buscar produto
    const prodResp = await Bridge.buscarProduto(codigo);
    if (!prodResp || !prodResp.sucesso) return;

    const produto = prodResp.dados;

    // Usar quantidade pendente (definida via "*") ou pedir se peso variavel
    let qtde = this._qtdePendente;
    if (produto.pesovariavel === 'S' && qtde === 1) {
      const peso = await Dialog.prompt('Peso', 'Informe o peso/quantidade:', 'Quantidade', '1');
      if (!peso) return;
      qtde = Utils.parseMoney(peso);
      if (qtde <= 0) { Toast.error('Quantidade invalida'); return; }
    }

    // Adicionar item (com vendedor, se informado)
    const codVendedor = parseInt(document.getElementById('input-vendedor').value) || 0;
    const itemResp = await Bridge.adicionarItem(produto.codprod, qtde, 0, codVendedor);
    if (!itemResp || !itemResp.sucesso) return;

    // Resetar quantidade pendente para 1
    this._setQuantidadePendente(1);

    // Atualizar grid
    this.adicionarItemNaGrid(itemResp.dados);
    this.atualizarTotais(itemResp.dados.totalCupom);

    // Destaque do ultimo item
    this._mostrarUltimoItem(itemResp.dados.descricao, itemResp.dados.valorTotal);

    barcodeInput.focus();
  },

  // ===== GRID DE ITENS =====
  adicionarItemNaGrid(item) {
    const tbody = document.getElementById('items-tbody');
    const tr = document.createElement('tr');
    tr.id = 'item-' + item.numSeqItem;
    tr.dataset.seq = item.numSeqItem;

    tr.innerHTML = `
      <td class="col-seq">${item.numSeqItem}</td>
      <td class="col-cod">${item.codprod}</td>
      <td class="col-desc">${item.descricao}</td>
      <td class="col-qtd">${Utils.formatMoney(item.quantidade)}</td>
      <td class="col-unit">${Utils.formatMoney(item.precoUnit)}</td>
      <td class="col-total">${Utils.formatMoney(item.valorTotal)}</td>
    `;

    tbody.appendChild(tr);

    // Scroll para o ultimo item
    const container = document.querySelector('.items-grid-container');
    container.scrollTop = container.scrollHeight;

    // Atualizar badge de qtd
    const rows = tbody.querySelectorAll('tr:not(.item-cancelled)');
    document.getElementById('pos-qtd-itens').textContent = rows.length + ' itens';
  },

  async recarregarItens() {
    const resp = await Bridge.obterItensCupom();
    if (!resp || !resp.sucesso) return;

    const tbody = document.getElementById('items-tbody');
    tbody.innerHTML = '';
    this.itens = resp.dados;

    resp.dados.forEach(item => {
      const tr = document.createElement('tr');
      tr.id = 'item-' + item.seq;
      tr.dataset.seq = item.seq;
      if (item.cancelado) tr.classList.add('item-cancelled');
      if (item.emOferta) tr.classList.add('item-offer');

      tr.innerHTML = `
        <td class="col-seq">${item.seq}</td>
        <td class="col-cod">${item.codprod}</td>
        <td class="col-desc">${item.descricao}</td>
        <td class="col-qtd">${Utils.formatMoney(item.quantidade)}</td>
        <td class="col-unit">${Utils.formatMoney(item.precoUnit)}</td>
        <td class="col-total">${Utils.formatMoney(item.valorTotal)}</td>
      `;
      tbody.appendChild(tr);
    });

    const rows = tbody.querySelectorAll('tr:not(.item-cancelled)');
    document.getElementById('pos-qtd-itens').textContent = rows.length + ' itens';
  },

  atualizarTotais(total) {
    document.getElementById('pos-subtotal').textContent = Utils.formatMoney(total);
    document.getElementById('pos-total').textContent = Utils.formatCurrency(total);
  },

  async atualizarResumo() {
    const resp = await Bridge.obterResumoCupom();
    if (!resp || !resp.sucesso) return;

    const d = resp.dados;
    document.getElementById('pos-subtotal').textContent = Utils.formatMoney(d.subtotal);
    document.getElementById('pos-desconto').textContent = Utils.formatMoney(d.desconto);
    document.getElementById('pos-acrescimo').textContent = Utils.formatMoney(d.acrescimo);
    document.getElementById('pos-total').textContent = Utils.formatCurrency(d.total);
  },

  _mostrarUltimoItem(desc, valor) {
    const el = document.getElementById('last-item-highlight');
    document.getElementById('last-item-desc').textContent = desc;
    document.getElementById('last-item-val').textContent = Utils.formatCurrency(valor);
    el.classList.remove('hidden');

    // Esconder apos 5 segundos
    setTimeout(() => el.classList.add('hidden'), 5000);
  },

  // ===== ACOES =====
  async solicitarDesconto() {
    if (this.estado !== 'registrando' && this.estado !== 'pagamento') return;
    const valor = await Dialog.prompt('Desconto', 'Informe o valor do desconto:', 'Valor (R$)', '0,00');
    if (valor) {
      const resp = await Bridge.aplicarDesconto(Utils.parseMoney(valor), 'valor');
      if (resp && resp.sucesso) {
        Toast.success('Desconto aplicado');
        this.atualizarResumo();
      }
    }
  },

  abrirPagamento() {
    if (this.estado !== 'registrando' && this.estado !== 'pagamento') {
      Toast.warning('Nao ha venda em andamento');
      return;
    }
    this.setEstado('pagamento');
    Payment.open();
  },

  async cancelarItem() {
    if (this.estado !== 'registrando') return;
    const seq = await Dialog.prompt('Cancelar Item', 'Informe o numero do item:', 'Num. Item', '');
    if (seq) {
      const resp = await Bridge.removerItem(parseInt(seq));
      if (resp && resp.sucesso) {
        const tr = document.getElementById('item-' + seq);
        if (tr) tr.classList.add('item-cancelled');
        Toast.success('Item cancelado');
        this.atualizarResumo();
      }
    }
  },

  async cancelarVenda() {
    if (this.estado === 'livre') return;
    const confirmou = await Dialog.confirm('Cancelar Venda', 'Deseja cancelar toda a venda?');
    if (confirmou) {
      const resp = await Bridge.cancelarVenda();
      if (resp && resp.sucesso) {
        this.limparVenda();
        Toast.warning('Venda cancelada');
      }
    }
  },

  limparVenda() {
    document.getElementById('items-tbody').innerHTML = '';
    document.getElementById('pos-qtd-itens').textContent = '0 itens';
    document.getElementById('pos-subtotal').textContent = '0,00';
    document.getElementById('pos-desconto').textContent = '0,00';
    document.getElementById('pos-acrescimo').textContent = '0,00';
    document.getElementById('pos-total').textContent = 'R$ 0,00';
    document.getElementById('last-item-highlight').classList.add('hidden');
    document.getElementById('payment-summary').classList.add('hidden');

    this.cupomId = 0;
    this.numCupom = 0;
    this.itens = [];
    this._setQuantidadePendente(1);
    Customers.limparConsumidor();
    this.setEstado('livre');
    this.voltarBarcode();
  },

  async solicitarSangria() {
    const valor = await Dialog.prompt('Sangria', 'Informe o valor da sangria:', 'Valor (R$)', '0,00');
    if (valor) {
      const motivo = await Dialog.prompt('Sangria', 'Informe o motivo:', 'Motivo', 'Sangria');
      if (motivo) {
        const resp = await Bridge.efetuarSangria(Utils.parseMoney(valor), motivo);
        if (resp && resp.sucesso) Toast.success(resp.mensagem);
      }
    }
  },

  async solicitarSuprimento() {
    const valor = await Dialog.prompt('Suprimento', 'Informe o valor do suprimento:', 'Valor (R$)', '0,00');
    if (valor) {
      const resp = await Bridge.efetuarSuprimento(Utils.parseMoney(valor));
      if (resp && resp.sucesso) Toast.success(resp.mensagem);
    }
  },

  async abrirPreVenda() {
    // Placeholder - sera expandido
    Toast.info('Pre-venda: funcionalidade em desenvolvimento');
  },

  async solicitarFechamento() {
    if (this.estado !== 'livre') {
      Toast.warning('Finalize a venda antes de fechar o caixa');
      return;
    }

    const resp = await Bridge.fecharCaixa();
    if (resp && resp.sucesso) {
      const d = resp.dados;
      document.getElementById('fech-qtd-vendas').textContent = d.qtdVendas;
      document.getElementById('fech-total-vendas').textContent = Utils.formatCurrency(d.totalVendas);
      document.getElementById('fech-total-sangrias').textContent = Utils.formatCurrency(d.totalSangrias);
      document.getElementById('fech-total-suprimentos').textContent = Utils.formatCurrency(d.totalSuprimentos);
      document.getElementById('fech-saldo').textContent = Utils.formatCurrency(d.saldoDinheiro);
      Modal.open('modal-fechamento');
    }
  },

  voltarBarcode() {
    const input = document.getElementById('barcode-input');
    if (input) { input.value = ''; input.focus(); }
  },

  // Finalizar venda (chamado pelo Payment)
  async finalizarVendaCompleta(dadosFechamento) {
    Toast.success('Venda finalizada! Troco: ' + Utils.formatCurrency(dadosFechamento.troco));

    // Gerar NFCe
    const nfceResp = await Bridge.gerarNFCe(dadosFechamento.cupomId);
    if (nfceResp && nfceResp.sucesso) {
      Toast.info('NFCe gerada com sucesso');
    }

    this.limparVenda();
  }
};
