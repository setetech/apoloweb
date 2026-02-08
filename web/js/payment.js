/* ========================================================
   ApoloWeb - Modulo de Pagamento
   ======================================================== */

const Payment = {
  init() {
    this._bindTabs();
    this._bindButtons();
    this._registerKeyboard();
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
  },

  _registerKeyboard() {
    Keyboard.register('modal_modal-pagamento', {
      'F1': () => this._selectTab('pay-dinheiro'),
      'F2': () => this._selectTab('pay-cheque'),
      'F3': () => this._selectTab('pay-cartao'),
      'F4': () => this._selectTab('pay-pix'),
      'F5': () => this.finalizarVenda(),
      'F6': () => this._selectTab('pay-pos'),
      'F8': () => this.registrarPagamento(),
      'Escape': () => this.fechar()
    });
  },

  _selectTab(tabId) {
    const tab = document.querySelector(`#modal-pagamento .pay-tab[data-tab="${tabId}"]`);
    if (tab) tab.click();
  },

  async open() {
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
        const item = document.createElement('div');
        item.className = 'pay-list-item';
        item.innerHTML = `
          <span>${p.descricao || p.codcob}</span>
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
        break;

      case 'pay-cobranca':
        dados = {
          codcob: '05',
          valor: Utils.parseMoney(document.getElementById('pay-cobranca-valor').value),
          codplpag: parseInt(document.getElementById('pay-cobranca-plano').value) || 0,
          dtvenc: document.getElementById('pay-cobranca-venc').value
        };
        break;

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

    const resp = await Bridge.registrarPagamento(dados);
    if (resp && resp.sucesso) {
      Toast.success('Pagamento registrado');
      this._limparInputsAtivos();
      await this.atualizarResumo();
    }
  },

  async finalizarVenda() {
    const resp = await Bridge.finalizarVenda();
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
