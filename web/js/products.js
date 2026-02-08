/* ========================================================
   ApoloWeb - Modulo de Busca de Produtos
   ======================================================== */

const Products = {
  _selectedIndex: -1,
  _results: [],

  init() {
    const searchInput = document.getElementById('search-produto');

    searchInput.addEventListener('input', Utils.debounce(async () => {
      const filtro = searchInput.value.trim();
      if (filtro.length < 2) return;
      await this._pesquisar(filtro);
    }, 300));

    searchInput.addEventListener('keydown', (e) => {
      if (e.key === 'ArrowDown') { e.preventDefault(); this._moverSelecao(1); }
      else if (e.key === 'ArrowUp') { e.preventDefault(); this._moverSelecao(-1); }
      else if (e.key === 'Enter') { e.preventDefault(); this._selecionarProduto(); }
    });

    Keyboard.register('modal_modal-produtos', {
      'Escape': () => this.close()
    });
  },

  open() {
    Modal.open('modal-produtos');
    const searchInput = document.getElementById('search-produto');
    searchInput.value = '';
    document.getElementById('search-produto-tbody').innerHTML = '';
    this._selectedIndex = -1;
    this._results = [];
    setTimeout(() => searchInput.focus(), 200);
  },

  close() {
    Modal.close('modal-produtos');
  },

  async _pesquisar(filtro) {
    const resp = await Bridge.listarProdutos(filtro);
    if (!resp || !resp.sucesso) return;

    this._results = resp.dados;
    this._selectedIndex = -1;
    const tbody = document.getElementById('search-produto-tbody');
    tbody.innerHTML = '';

    resp.dados.forEach((prod, idx) => {
      const tr = document.createElement('tr');
      tr.dataset.index = idx;

      const emOferta = prod.poferta > 0;
      if (emOferta) tr.classList.add('offer');

      tr.innerHTML = `
        <td>${prod.codbarra || ''}</td>
        <td>${prod.descricao}</td>
        <td>${prod.unidade || ''}</td>
        <td>${prod.embalagem || ''}</td>
        <td style="text-align:right; font-family: var(--font-mono);">${Utils.formatMoney(prod.pvenda)}</td>
        <td style="text-align:right; font-family: var(--font-mono);">${Utils.formatMoney(prod.pvendaatac)}</td>
        <td style="text-align:right; font-family: var(--font-mono); color: ${emOferta ? 'var(--accent-warning)' : ''}">${emOferta ? Utils.formatMoney(prod.poferta) : '-'}</td>
        <td style="text-align:right; font-family: var(--font-mono);">${Utils.formatMoney(prod.qtdisponivel)}</td>
      `;

      tr.addEventListener('click', () => {
        this._selectedIndex = idx;
        this._atualizarSelecao();
        this._selecionarProduto();
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
    const tbody = document.getElementById('search-produto-tbody');
    tbody.querySelectorAll('tr').forEach(tr => tr.classList.remove('selected'));
    const selected = tbody.querySelector(`tr[data-index="${this._selectedIndex}"]`);
    if (selected) {
      selected.classList.add('selected');
      selected.scrollIntoView({ block: 'nearest' });
    }
  },

  async _selecionarProduto() {
    if (this._selectedIndex < 0 || this._selectedIndex >= this._results.length) return;
    const prod = this._results[this._selectedIndex];
    this.close();

    // Adicionar ao PDV
    const barcodeInput = document.getElementById('barcode-input');
    barcodeInput.value = prod.codbarra || prod.codprod;
    POS.processarCodigo(barcodeInput.value);
  }
};
