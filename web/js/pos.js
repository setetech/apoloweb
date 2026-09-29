/* ========================================================
   ApoloWeb - Modulo PDV (Frente de Caixa)
   ======================================================== */

const POS = {
  cupomId: 0,
  numCupom: 0,
  estado: 'livre', // livre, registrando, pagamento
  itens: [],
  _qtdePendente: 1,
  _itemSelecionado: 0,

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

    // Preview do comprovante de sangria/suprimento
    document.getElementById('btn-comprovante-fechar').addEventListener('click', () => {
      Modal.close('modal-comprovante');
    });
    document.getElementById('btn-comprovante-imprimir').addEventListener('click', async () => {
      const vias = this._comprovanteVias || [];
      Modal.close('modal-comprovante');
      const resp = await Bridge.imprimirComprovante(vias);
      if (resp && resp.sucesso) Toast.success(resp.mensagem);
    });

    // Selecao de item na grid (define o alvo padrao do desconto/cancelamento)
    document.getElementById('items-tbody').addEventListener('click', (e) => {
      const tr = e.target.closest('tr');
      if (tr && tr.dataset.seq) this.selecionarItem(parseInt(tr.dataset.seq));
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
      'Shift+F3': () => this.solicitarDescontoItem(),
      'F4': () => this.abrirPagamento(),
      'F5': () => this.forcarCargaGeral(),
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

  // F5 - Carga geral: forca o download completo do Oracle (ignora a
  // verificacao de data em msapolo_caixa). So com o caixa livre.
  async forcarCargaGeral() {
    const ok = await Dialog.confirm('Carga Geral',
      'Baixar TODOS os dados do servidor agora (produtos, precos, clientes...)?');
    if (!ok) return;
    await Bridge.call('forcarSincronizacao');
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

    // Balanca: barcode comeca com "2" e tem 13 digitos
    // Formato: 2 X CCCCC PPPPP D  (C=codigo pos 3 tam 5, P=preco pos 8 tam 5)
    // Mas antes: o ERP gera EAN interno "2000000" + codprod para produto sem
    // EAN, com o mesmo prefixo 2. Se o codigo inteiro e' de um produto, ele
    // manda - senao o VASO H88 (2000000169323) virava etiqueta "00001" de
    // R$ 693,23 e o caixa registrava outro produto.
    let codigoBusca = codigo;
    let precoBalanca = 0;
    let exatoResp = null;
    if (codigo.length === 13 && codigo.charAt(0) === '2') {
      exatoResp = await Bridge.send('buscarProduto', { codigo, exato: true });
    }
    if (codigo.length === 13 && codigo.charAt(0) === '2' &&
        !(exatoResp && exatoResp.sucesso)) {
      const codProdBalanca = codigo.substring(2, 7);  // pos 3, tam 5 (0-based: 2..6)
      const precoStr = codigo.substring(7, 12);       // pos 8, tam 5 (0-based: 7..11)
      precoBalanca = parseInt(precoStr, 10) / 100;     // ex: "01250" -> 12.50
      codigoBusca = codProdBalanca;
    }

    // Buscar produto. Para etiqueta de balanca, a busca pelo codigo curto e
    // silenciosa: se nao achar, cai no barcode completo (que mostra o erro).
    let prodResp;
    if (exatoResp && exatoResp.sucesso) {
      prodResp = exatoResp;
    } else if (precoBalanca > 0) {
      prodResp = await Bridge.send('buscarProduto', { codigo: codigoBusca });
      if (!prodResp || !prodResp.sucesso) {
        codigoBusca = codigo;
        precoBalanca = 0;
        prodResp = await Bridge.buscarProduto(codigoBusca);
      }
    } else {
      prodResp = await Bridge.buscarProduto(codigoBusca);
    }
    if (!prodResp || !prodResp.sucesso) return;

    const produto = prodResp.dados;

    // Codigo que identifica a embalagem bipada (resolve a unidade no Delphi)
    let codBarraBipado = codigoBusca;

    // Se balanca detectada mas produto nao e peso variavel, buscar pelo barcode original
    let precoManual = 0;
    let precoEtiqueta = 0;
    let qtde = this._qtdePendente;
    // Etiqueta de balanca vale para produto de peso variavel OU vendido por
    // KG (o cadastro nem sempre marca pesovariavel=S)
    const unidProd = (produto.unidade || '').trim().toUpperCase();
    const aceitaBalanca = produto.pesovariavel === 'S' || unidProd === 'KG';
    if (precoBalanca > 0 && aceitaBalanca) {
      // A etiqueta traz o PRECO pesado; a quantidade e calculada no Delphi
      // (preco da etiqueta / preco vigente do produto)
      precoEtiqueta = precoBalanca;
      qtde = 1;
      // Barcode cadastrado do produto (ex: "2"), para resolver a embalagem KG
      codBarraBipado = produto.codbarra || codigoBusca;
    } else if (precoBalanca > 0 && !aceitaBalanca) {
      // Nao e peso variavel - tentar buscar pelo barcode completo
      const prodResp2 = await Bridge.buscarProduto(codigo);
      if (!prodResp2 || !prodResp2.sucesso) return;
      Object.assign(produto, prodResp2.dados);
      codBarraBipado = codigo;
      precoBalanca = 0;
    }

    // Usar quantidade pendente (definida via "*") ou pedir se peso variavel (sem balanca)
    if (produto.pesovariavel === 'S' && precoBalanca === 0 && qtde === 1) {
      const peso = await Dialog.prompt('Peso', 'Informe o peso/quantidade:', 'Quantidade', '1');
      if (!peso) return;
      qtde = Utils.parseMoney(peso);
      if (qtde <= 0) { Toast.error('Quantidade invalida'); return; }
    }

    // Quantidade fracionada so e permitida para unidades KG ou metro
    if (qtde % 1 !== 0) {
      const unid = (produto.unidade || '').trim().toUpperCase();
      if (unid !== 'KG' && unid !== 'MT' && unid !== 'M') {
        Toast.error('Produto com unidade "' + unid + '" nao permite quantidade fracionada');
        this._setQuantidadePendente(1);
        barcodeInput.focus();
        return;
      }
    }

    // Adicionar item (com vendedor, se informado)
    const codVendedor = parseInt(document.getElementById('input-vendedor').value) || 0;
    const itemResp = await Bridge.adicionarItem(produto.codprod, qtde, precoManual, codVendedor, codBarraBipado, precoEtiqueta);
    if (!itemResp || !itemResp.sucesso) return;

    // Resetar quantidade pendente para 1
    this._setQuantidadePendente(1);

    // Atualizar grid
    this.adicionarItemNaGrid(itemResp.dados);
    this.selecionarItem(itemResp.dados.numSeqItem);
    await this.atualizarResumo();

    // Destaque do ultimo item
    this._mostrarUltimoItem(itemResp.dados.descricao, itemResp.dados.valorTotal);

    barcodeInput.focus();
  },

  // ===== GRID DE ITENS =====
  _celulasItem(seq, codprod, descricao, unidade, quantidade, precoUnit, desconto, valorTotal) {
    const desc = desconto || 0;
    return `
      <td class="col-seq">${seq}</td>
      <td class="col-cod">${codprod}</td>
      <td class="col-desc">${descricao}</td>
      <td class="col-un">${unidade || ''}</td>
      <td class="col-qtd">${Utils.formatMoney(quantidade)}</td>
      <td class="col-unit">${Utils.formatMoney(precoUnit)}</td>
      <td class="col-descv">${desc > 0 ? '-' + Utils.formatMoney(desc) : ''}</td>
      <td class="col-total">${Utils.formatMoney(valorTotal)}</td>
    `;
  },

  adicionarItemNaGrid(item) {
    const tbody = document.getElementById('items-tbody');
    const tr = document.createElement('tr');
    tr.id = 'item-' + item.numSeqItem;
    tr.dataset.seq = item.numSeqItem;
    if (item.desconto > 0) tr.classList.add('item-discounted');

    tr.innerHTML = this._celulasItem(item.numSeqItem, item.codprod, item.descricao,
      item.unidade, item.quantidade, item.precoUnit, item.desconto, item.valorTotal);

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
      if (item.desconto > 0) tr.classList.add('item-discounted');

      tr.innerHTML = this._celulasItem(item.seq, item.codprod, item.descricao,
        item.unidade, item.quantidade, item.precoUnit, item.desconto, item.valorTotal);
      tbody.appendChild(tr);
    });

    const rows = tbody.querySelectorAll('tr:not(.item-cancelled)');
    document.getElementById('pos-qtd-itens').textContent = rows.length + ' itens';

    // Reaplicar o destaque da linha selecionada
    if (this._itemSelecionado) this.selecionarItem(this._itemSelecionado);
  },

  selecionarItem(seq) {
    const tbody = document.getElementById('items-tbody');
    tbody.querySelectorAll('tr.item-selected').forEach(tr => tr.classList.remove('item-selected'));

    const tr = document.getElementById('item-' + seq);
    if (!tr || tr.classList.contains('item-cancelled')) {
      this._itemSelecionado = 0;
      return;
    }
    tr.classList.add('item-selected');
    this._itemSelecionado = seq;
  },

  // Item alvo padrao das acoes por item: o selecionado ou, na falta, o ultimo ativo
  _itemAlvo() {
    if (this._itemSelecionado) return this._itemSelecionado;
    const rows = document.querySelectorAll('#items-tbody tr:not(.item-cancelled)');
    if (!rows.length) return 0;
    return parseInt(rows[rows.length - 1].dataset.seq) || 0;
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

  // Executa uma action que pode exigir permissao (rotina 8002). Se o backend
  // responder dados.requerAutorizacao, pede matricula+senha de um autorizador
  // e reenvia; repete enquanto a autorizacao for recusada (senha errada etc).
  async _executarComAutorizacao(executar) {
    let resp = await executar(null);
    while (resp && !resp.sucesso && resp.dados && resp.dados.requerAutorizacao) {
      const mat = await Dialog.prompt('Autorizacao',
        'Informe a matricula do autorizador:', 'Matricula', '', false);
      if (!mat) return resp;

      const senha = await Dialog.prompt('Autorizacao',
        'Informe a senha do autorizador:', 'Senha', '', false, 'password');
      if (senha === null) return resp;

      resp = await executar({
        supMatricula: parseInt(mat) || 0,
        supSenha: String(senha)
      });
    }
    return resp;
  },

  // Desconto no TOTAL da venda (controle 3 da rotina 8002)
  async solicitarDesconto() {
    if (this.estado !== 'registrando' && this.estado !== 'pagamento') return;
    const valor = await Dialog.prompt('Desconto', 'Informe o valor do desconto:', 'Valor (R$)', '0,00');
    if (valor) {
      const resp = await this._executarComAutorizacao(aut =>
        Bridge.aplicarDesconto(Utils.parseMoney(valor), 'valor', aut));
      if (resp && resp.sucesso) {
        Toast.success('Desconto aplicado');
        this.atualizarResumo();
      }
    }
  },

  // Shift+F3 - Desconto em UM item. Aceita "5,00" (R$) ou "10%" (percentual);
  // valor zerado remove o desconto do item.
  async solicitarDescontoItem() {
    if (this.estado !== 'registrando') {
      Toast.warning('Desconto por item so durante o registro');
      return;
    }

    const alvo = this._itemAlvo();
    if (!alvo) {
      Toast.warning('Nenhum item registrado');
      return;
    }

    const seqStr = await Dialog.prompt('Desconto no Item',
      'Informe o numero do item:', 'Num. Item', String(alvo), false);
    if (!seqStr) return;

    const seq = parseInt(seqStr);
    if (!seq) { Toast.error('Numero de item invalido'); return; }

    const item = this.itens.find(i => i.seq === seq) || this._descricaoItemGrid(seq);
    const titulo = item ? Utils.truncate(item.descricao, 30) : 'Item ' + seq;

    const entrada = await Dialog.prompt('Desconto - ' + titulo,
      'Desconto em R$ ou % (ex: 2,50 ou 10%). Zero remove:', 'Desconto', '', false);
    if (!entrada) return;

    const bruto = String(entrada).trim();
    const percentual = bruto.endsWith('%');
    const valor = Utils.parseMoney(percentual ? bruto.slice(0, -1).trim() : bruto);

    if (isNaN(valor) || valor < 0) { Toast.error('Desconto invalido'); return; }

    const resp = await this._executarComAutorizacao(aut =>
      Bridge.aplicarDescontoItem(seq, valor, percentual ? 'percentual' : 'valor', aut));
    if (resp && resp.sucesso) {
      Toast.success(resp.mensagem);
      await this.recarregarItens();
      await this.atualizarResumo();
      this.voltarBarcode();
    }
  },

  // Descricao lida da linha ja' renderizada (this.itens so' e' populado no reload)
  _descricaoItemGrid(seq) {
    const tr = document.getElementById('item-' + seq);
    if (!tr) return null;
    const td = tr.querySelector('.col-desc');
    return td ? { descricao: td.textContent } : null;
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
    const alvo = this._itemAlvo();
    const seq = await Dialog.prompt('Cancelar Item', 'Informe o numero do item:',
      'Num. Item', alvo ? String(alvo) : '', false);
    if (seq) {
      const resp = await this._executarComAutorizacao(aut =>
        Bridge.removerItem(parseInt(seq), aut));
      if (resp && resp.sucesso) {
        const tr = document.getElementById('item-' + seq);
        if (tr) {
          tr.classList.add('item-cancelled');
          tr.classList.remove('item-selected');
        }
        if (this._itemSelecionado === parseInt(seq)) this._itemSelecionado = 0;
        Toast.success('Item cancelado');
        this.atualizarResumo();
      }
    }
  },

  // Cancelamento da venda (controle 5 da rotina 8002)
  async cancelarVenda() {
    // Tela livre: ainda assim consultar o backend - o estado persistido pode
    // ter ficado preso em "venda em andamento" (queda de energia/encerramento
    // abrupto), o que bloqueia sync e carga geral. O backend normaliza (sem
    // exigir permissao) ou acha um cupom orfao e ai' pede autorizacao.
    if (this.estado === 'livre') {
      const resp = await this._executarComAutorizacao(aut => Bridge.cancelarVenda(aut));
      if (resp && resp.sucesso) {
        this.limparVenda();
        Toast.info(resp.mensagem || 'Estado do caixa normalizado');
      }
      return;
    }
    const confirmou = await Dialog.confirm('Cancelar Venda', 'Deseja cancelar toda a venda?');
    if (confirmou) {
      const resp = await this._executarComAutorizacao(aut => Bridge.cancelarVenda(aut));
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
    this._itemSelecionado = 0;
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
        const resp = await this._executarComAutorizacao(aut =>
          Bridge.efetuarSangria(Utils.parseMoney(valor), motivo, aut));
        if (resp && resp.sucesso) {
          Toast.success(resp.mensagem);
          this._mostrarComprovante('Comprovante de Sangria', resp.dados);
        }
      }
    }
  },

  async solicitarSuprimento() {
    const valor = await Dialog.prompt('Suprimento', 'Informe o valor do suprimento:', 'Valor (R$)', '0,00');
    if (valor) {
      const resp = await Bridge.efetuarSuprimento(Utils.parseMoney(valor));
      if (resp && resp.sucesso) {
        Toast.success(resp.mensagem);
        this._mostrarComprovante('Comprovante de Suprimento', resp.dados);
      }
    }
  },

  // Preview do comprovante antes de imprimir: mostra a 1a via (a 2a so muda o
  // rotulo) e guarda as duas para o botao Imprimir mandar ao Delphi
  _mostrarComprovante(titulo, dados) {
    const vias = dados && dados.vias;
    if (!vias || !vias.length) return;
    this._comprovanteVias = vias;
    document.getElementById('comprovante-title').textContent = titulo;
    document.getElementById('comprovante-preview').textContent = vias[0];
    Modal.open('modal-comprovante');
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

    const resp = await this._executarComAutorizacao(aut => Bridge.fecharCaixa(aut));
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

  // Restaurar venda em andamento (recuperacao apos queda de energia)
  async restaurarVenda(cupomId, numCupom, estado) {
    this.cupomId = cupomId;
    this.numCupom = numCupom;
    this.setEstado(estado || 'registrando');
    await this.recarregarItens();
    await this.atualizarResumo();
    Toast.info('Venda #' + numCupom + ' restaurada');
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
