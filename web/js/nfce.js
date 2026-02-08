/* ========================================================
   ApoloWeb - Modulo NFCe e Contingencia
   ======================================================== */

const NFCePanel = {
  init() {
    this._bindTabs();
    this._bindButtons();
    this._registerKeyboard();
  },

  _bindTabs() {
    document.querySelectorAll('#modal-nfce .pay-tab').forEach(tab => {
      tab.addEventListener('click', () => {
        document.querySelectorAll('#modal-nfce .pay-tab').forEach(t => t.classList.remove('active'));
        document.querySelectorAll('#modal-nfce .pay-panel').forEach(p => p.classList.remove('active'));
        tab.classList.add('active');
        const panel = document.getElementById(tab.dataset.tab);
        if (panel) panel.classList.add('active');
      });
    });
  },

  _bindButtons() {
    document.getElementById('btn-entrar-contingencia').addEventListener('click', () => this.entrarContingencia());
    document.getElementById('btn-sair-contingencia').addEventListener('click', () => this.sairContingencia());
    document.getElementById('btn-retransmitir').addEventListener('click', () => this.retransmitir());
  },

  _registerKeyboard() {
    Keyboard.register('modal_modal-nfce', {
      'Escape': () => this.close()
    });
  },

  async open() {
    Modal.open('modal-nfce');
    await this.carregarPendentes();
    await this.atualizarStatusConexao();
  },

  close() {
    Modal.close('modal-nfce');
  },

  async carregarPendentes() {
    const resp = await Bridge.listarNFCePendentes();
    if (!resp || !resp.sucesso) return;

    const tbody = document.getElementById('nfce-pendentes-tbody');
    tbody.innerHTML = '';

    resp.dados.forEach(doc => {
      const tr = document.createElement('tr');
      const statusClass = doc.status === 'PENDENTE' ? 'text-warning' :
                          doc.status === 'AUTORIZADO' ? 'text-success' : 'text-danger';

      tr.innerHTML = `
        <td style="font-size:0.75rem; font-family: var(--font-mono);">${Utils.truncate(doc.chaveNFe, 20)}</td>
        <td>${doc.numNota}</td>
        <td>${doc.numCupom}</td>
        <td style="text-align:right; font-family: var(--font-mono);">${Utils.formatMoney(doc.valorVenda)}</td>
        <td class="${statusClass}">${doc.status}</td>
        <td style="text-align:center;">${doc.tentativas}</td>
        <td style="font-size:0.8rem; color: var(--accent-danger);">${Utils.truncate(doc.ultimoErro, 30)}</td>
      `;
      tbody.appendChild(tr);
    });

    if (resp.dados.length === 0) {
      tbody.innerHTML = '<tr><td colspan="7" style="text-align:center; color: var(--text-muted); padding: 20px;">Nenhum documento pendente</td></tr>';
    }
  },

  async atualizarStatusConexao() {
    const resp = await Bridge.obterStatusConexao();
    if (!resp || !resp.sucesso) return;

    const badge = document.getElementById('contingencia-badge');
    const headerBadge = document.getElementById('pos-status-badge');

    if (resp.dados.online) {
      badge.textContent = 'ONLINE';
      badge.className = 'status-badge status-online';
      headerBadge.textContent = 'ONLINE';
      headerBadge.className = 'status-badge status-online';
    } else {
      const tipo = resp.dados.tipo || 'OFFLINE';
      badge.textContent = tipo;
      badge.className = 'status-badge status-contingencia';
      headerBadge.textContent = 'CONTINGENCIA';
      headerBadge.className = 'status-badge status-contingencia';
    }
  },

  async entrarContingencia() {
    const tipo = document.getElementById('contingencia-tipo').value;
    const justificativa = document.getElementById('contingencia-justificativa').value;

    if (!justificativa.trim()) {
      Toast.warning('Informe a justificativa para entrar em contingencia');
      return;
    }

    const resp = await Bridge.entrarContingencia(tipo, justificativa);
    if (resp && resp.sucesso) {
      Toast.warning('Contingencia ativada: ' + tipo);
      await this.atualizarStatusConexao();
    }
  },

  async sairContingencia() {
    const resp = await Bridge.sairContingencia();
    if (resp && resp.sucesso) {
      Toast.success('Modo normal restaurado');
      await this.atualizarStatusConexao();
    }
  },

  async retransmitir() {
    Toast.info('Retransmitindo documentos pendentes...');
    const resp = await Bridge.retransmitirContingencia();
    if (resp && resp.sucesso) {
      Toast.success('Retransmissao concluida');
      await this.carregarPendentes();
    }
  }
};
