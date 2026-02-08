/* ========================================================
   ApoloWeb - Modulo de Identificacao do Consumidor
   ======================================================== */

const Customers = {
  _selectedIndex: -1,
  _results: [],
  _consumidorAtual: null,

  init() {
    // Input de CPF/CNPJ para identificacao direta
    const cpfInput = document.getElementById('input-cpfcnpj');
    cpfInput.addEventListener('keydown', (e) => {
      if (e.key === 'Enter') {
        e.preventDefault();
        this._identificarConsumidor();
      }
    });
    cpfInput.addEventListener('input', () => {
      this._aplicarMascaraCpfCnpj(cpfInput);
    });

    document.getElementById('btn-identificar-consumidor').addEventListener('click', () => {
      this._identificarConsumidor();
    });

    // Input de busca por nome/codigo
    const searchInput = document.getElementById('search-cliente');

    searchInput.addEventListener('input', Utils.debounce(async () => {
      const filtro = searchInput.value.trim();
      if (filtro.length < 2) return;
      await this._pesquisar(filtro);
    }, 300));

    searchInput.addEventListener('keydown', (e) => {
      if (e.key === 'ArrowDown') { e.preventDefault(); this._moverSelecao(1); }
      else if (e.key === 'ArrowUp') { e.preventDefault(); this._moverSelecao(-1); }
      else if (e.key === 'Enter') { e.preventDefault(); this._selecionarCliente(); }
    });

    Keyboard.register('modal_modal-clientes', {
      'Escape': () => this.close()
    });
  },

  open() {
    Modal.open('modal-clientes');
    const cpfInput = document.getElementById('input-cpfcnpj');
    cpfInput.value = '';
    document.getElementById('search-cliente').value = '';
    document.getElementById('search-cliente-tbody').innerHTML = '';
    document.getElementById('consumer-id-result').classList.add('hidden');
    document.getElementById('consumer-id-result').classList.remove('found', 'not-found');
    this._selectedIndex = -1;
    this._results = [];
    setTimeout(() => cpfInput.focus(), 200);
  },

  close() {
    Modal.close('modal-clientes');
  },

  // Retorna dados do consumidor vinculado a venda atual
  getConsumidorAtual() {
    return this._consumidorAtual;
  },

  // Limpa o consumidor (chamado ao limpar venda)
  limparConsumidor() {
    this._consumidorAtual = null;
    const badge = document.getElementById('pos-cliente-info');
    badge.textContent = '';
    badge.classList.add('hidden');
  },

  // Exibe o consumidor identificado no header do PDV
  _exibirConsumidorNoPDV(dados) {
    this._consumidorAtual = dados;
    const badge = document.getElementById('pos-cliente-info');
    const cpfFormatado = this._formatarCpfCnpj(dados.cpfCnpj);
    if (dados.encontrado) {
      badge.textContent = dados.nome + ' - ' + cpfFormatado;
    } else {
      badge.textContent = 'CPF/CNPJ: ' + cpfFormatado;
    }
    badge.classList.remove('hidden');
  },

  // === IDENTIFICACAO POR CPF/CNPJ ===
  async _identificarConsumidor() {
    const cpfInput = document.getElementById('input-cpfcnpj');
    const cpfCnpj = cpfInput.value.trim();

    if (!cpfCnpj) {
      Toast.warning('Informe o CPF ou CNPJ');
      cpfInput.focus();
      return;
    }

    // Verificar se ha venda em andamento
    if (POS.estado === 'livre') {
      Toast.warning('Inicie uma venda antes de identificar o consumidor');
      return;
    }

    const resp = await Bridge.identificarConsumidor(cpfCnpj);
    if (!resp || !resp.sucesso) return;

    const dados = resp.dados;
    const resultEl = document.getElementById('consumer-id-result');
    const iconEl = document.getElementById('consumer-id-icon');
    const nomeEl = document.getElementById('consumer-id-nome');
    const detalheEl = document.getElementById('consumer-id-detalhe');

    resultEl.classList.remove('hidden', 'found', 'not-found');

    if (dados.encontrado) {
      resultEl.classList.add('found');
      iconEl.textContent = '\u2713';
      nomeEl.textContent = dados.nome;
      detalheEl.textContent = 'Cod: ' + dados.codcli + ' | ' + this._formatarCpfCnpj(dados.cpfCnpj) +
        (dados.cidade ? ' | ' + dados.cidade + '/' + dados.uf : '');
      Toast.success('Cliente identificado: ' + dados.nome);
    } else {
      resultEl.classList.add('not-found');
      iconEl.textContent = '\u2139';
      nomeEl.textContent = 'Consumidor nao cadastrado';
      detalheEl.textContent = 'CPF/CNPJ registrado na venda. Usando consumidor padrao (cod: ' + dados.codcli + ')';
      Toast.info('CPF/CNPJ registrado na venda');
    }

    this._exibirConsumidorNoPDV(dados);
    // Fechar modal apos identificacao
    setTimeout(() => this.close(), 1200);
  },

  // === BUSCA POR NOME/CODIGO ===
  async _pesquisar(filtro) {
    const resp = await Bridge.buscarCliente(filtro);
    if (!resp || !resp.sucesso) return;

    this._results = resp.dados;
    this._selectedIndex = -1;
    const tbody = document.getElementById('search-cliente-tbody');
    tbody.innerHTML = '';

    resp.dados.forEach((cli, idx) => {
      const tr = document.createElement('tr');
      tr.dataset.index = idx;

      tr.innerHTML = `
        <td>${cli.codcli}</td>
        <td>${cli.cpf_cnpj || ''}</td>
        <td>${cli.nome}</td>
        <td>${cli.cidade || ''}</td>
        <td>${cli.uf || ''}</td>
        <td style="text-align:right; font-family: var(--font-mono);">${Utils.formatMoney(cli.limiteCredito)}</td>
      `;

      tr.addEventListener('click', () => {
        this._selectedIndex = idx;
        this._atualizarSelecao();
        this._selecionarCliente();
      });

      tbody.appendChild(tr);
    });

    if (resp.dados.length > 0) {
      this._selectedIndex = 0;
      this._atualizarSelecao();
    }
  },

  _moverSelecao(delta) {
    if (this._results.length === 0) return;
    this._selectedIndex = Math.max(0, Math.min(this._results.length - 1, this._selectedIndex + delta));
    this._atualizarSelecao();
  },

  _atualizarSelecao() {
    const tbody = document.getElementById('search-cliente-tbody');
    tbody.querySelectorAll('tr').forEach(tr => tr.classList.remove('selected'));
    const selected = tbody.querySelector(`tr[data-index="${this._selectedIndex}"]`);
    if (selected) {
      selected.classList.add('selected');
      selected.scrollIntoView({ block: 'nearest' });
    }
  },

  async _selecionarCliente() {
    if (this._selectedIndex < 0 || this._selectedIndex >= this._results.length) return;
    const cli = this._results[this._selectedIndex];

    // Verificar se ha venda em andamento
    if (POS.estado === 'livre') {
      Toast.warning('Inicie uma venda antes de vincular o cliente');
      return;
    }

    const resp = await Bridge.vincularCliente(cli.codcli);
    if (!resp || !resp.sucesso) return;

    const dados = resp.dados;
    dados.encontrado = true;
    this._exibirConsumidorNoPDV(dados);

    this.close();
    Toast.success('Cliente vinculado: ' + dados.nome);
  },

  // === MASCARAS E FORMATACAO ===
  _aplicarMascaraCpfCnpj(input) {
    let v = input.value.replace(/\D/g, '');
    if (v.length <= 11) {
      // CPF: 000.000.000-00
      v = v.replace(/(\d{3})(\d)/, '$1.$2');
      v = v.replace(/(\d{3})(\d)/, '$1.$2');
      v = v.replace(/(\d{3})(\d{1,2})$/, '$1-$2');
    } else {
      // CNPJ: 00.000.000/0000-00
      v = v.substring(0, 14);
      v = v.replace(/^(\d{2})(\d)/, '$1.$2');
      v = v.replace(/^(\d{2})\.(\d{3})(\d)/, '$1.$2.$3');
      v = v.replace(/\.(\d{3})(\d)/, '.$1/$2');
      v = v.replace(/(\d{4})(\d{1,2})$/, '$1-$2');
    }
    input.value = v;
  },

  _formatarCpfCnpj(valor) {
    if (!valor) return '';
    const v = valor.replace(/\D/g, '');
    if (v.length === 11) {
      return v.replace(/(\d{3})(\d{3})(\d{3})(\d{2})/, '$1.$2.$3-$4');
    } else if (v.length === 14) {
      return v.replace(/(\d{2})(\d{3})(\d{3})(\d{4})(\d{2})/, '$1.$2.$3/$4-$5');
    }
    return valor;
  }
};
