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
    // Mesma acao na aba Pendentes: e' ali que o operador ve a fila travada
    document.getElementById('btn-retransmitir-pend').addEventListener('click', () => this.retransmitir());
    document.getElementById('btn-atualizar-pend').addEventListener('click', () => this.carregarPendentes());
    document.getElementById('btn-regerar-pend').addEventListener('click', () => this.regerarSelecionadas());
    document.getElementById('btn-descartar-pend').addEventListener('click', () => this.descartarSelecionados());
    document.getElementById('nfce-sel-todos').addEventListener('change', (e) => this.marcarTodos(e.target.checked));
    document.getElementById('btn-cancel-atualizar').addEventListener('click', () => this.carregarCancelaveis());
    Logo.init();
    TEFConfig.init();
    TEFAdm.init();
    ImpressoraConfig.init();
  },

  _registerKeyboard() {
    Keyboard.register('modal_modal-nfce', {
      'Escape': () => this.close()
    });
  },

  async open() {
    Modal.open('modal-nfce');
    await this.carregarPendentes();
    await this.carregarCancelaveis();
    await this.atualizarStatusConexao();
    await Logo.carregar();
    await TEFConfig.carregar();
    await TEFAdm.carregarTransacoes();
    await ImpressoraConfig.carregar();
  },

  // ===== CANCELAMENTO DE NFCe (evento 110111) =====

  async carregarCancelaveis() {
    const resp = await Bridge.listarNFCeCancelaveis();
    const tbody = document.getElementById('nfce-cancel-tbody');
    if (!tbody) return;
    tbody.innerHTML = '';

    if (!resp || !resp.sucesso || !resp.dados || resp.dados.length === 0) {
      tbody.innerHTML = '<tr><td colspan="7" style="text-align:center; color: var(--text-muted); padding: 20px;">Nenhuma NFCe autorizada hoje</td></tr>';
      return;
    }

    resp.dados.forEach(n => {
      const tr = document.createElement('tr');
      let prazo, prazoClass, acao = '';

      if (n.semNfce) {
        // Venda fechada (e ja' cobrada) que nunca teve a nota gerada - o
        // front nao chegou a pedir o gerarNFCe. So' o que falta e' emitir.
        prazo = 'SEM NFCe';
        prazoClass = 'text-danger';
        acao = `<button class="btn btn-warning btn-sm" data-emitir="${n.cupomId}">Emitir NFCe</button>`;
      } else if (n.cancelada) {
        prazo = 'CANCELADA';
        prazoClass = 'text-muted';
      } else if (!n.noPrazo) {
        // Fora dos 30 minutos a SEFAZ rejeita - nao adianta nem tentar
        prazo = 'fora do prazo';
        prazoClass = 'text-danger';
      } else {
        const restam = 30 - n.minutos;
        prazo = restam + ' min';
        prazoClass = restam <= 5 ? 'text-warning' : 'text-success';
        acao = `<button class="btn btn-danger btn-sm" data-cancelar="${n.cupomId}">Cancelar</button> `;
      }

      // A 2a via vale para qualquer nota autorizada nao cancelada, dentro ou
      // fora do prazo de cancelamento - reimprimir nao fala com a SEFAZ
      if (!n.cancelada && !n.semNfce) {
        acao += `<button class="btn btn-sm" data-reimprimir="${n.cupomId}">Reimprimir</button>`;
      }

      tr.innerHTML = `
        <td>${(n.dthrVenda || '').substring(11, 16)}</td>
        <td>${n.semNfce ? '-' : n.numNota}</td>
        <td>${n.numCupom}</td>
        <td style="text-align:right; font-family: var(--font-mono);">${Utils.formatMoney(n.valor)}</td>
        <td style="font-size:0.75rem; font-family: var(--font-mono);">${Utils.truncate(n.chaveNFe, 20)}</td>
        <td class="${prazoClass}" style="text-align:center;">${prazo}</td>
        <td class="col-acao">${acao}</td>
      `;

      const btn = tr.querySelector('[data-cancelar]');
      if (btn) btn.addEventListener('click', () => this.cancelarNota(n));
      const btnRe = tr.querySelector('[data-reimprimir]');
      if (btnRe) btnRe.addEventListener('click', () => this.reimprimirNota(n, btnRe));
      const btnEm = tr.querySelector('[data-emitir]');
      if (btnEm) btnEm.addEventListener('click', () => this.emitirNota(n, btnEm));
      tbody.appendChild(tr);
    });
  },

  // Emissao de uma venda que fechou sem nota. E' o mesmo gerarNFCe do fim da
  // venda: pega o proximo numero, manda para a SEFAZ (ou contingencia),
  // imprime o DANFCe e os comprovantes TEF e sobe o XML. O botao trava
  // enquanto roda porque cada chamada consome um numero de NFCe.
  async emitirNota(nota, btn) {
    const ok = await Dialog.confirm(
      'Emitir NFCe do cupom ' + nota.numCupom,
      `Venda de R$ ${Utils.formatMoney(nota.valor)} fechada sem nota fiscal. ` +
      'A NFCe sera emitida agora com o proximo numero e o cupom impresso. Continuar?'
    );
    if (!ok) return;

    if (btn) btn.disabled = true;
    try {
      const resp = await Bridge.gerarNFCe(nota.cupomId, true);
      if (resp && resp.sucesso) {
        Toast.success(resp.mensagem || 'NFCe emitida');
      }
    } finally {
      if (btn) btn.disabled = false;
      await this.carregarCancelaveis();
      await this.carregarPendentes();
    }
  },

  // ESCPOS imprime na hora; Sumatra pode demorar alguns segundos gerando o
  // PDF - o botao trava enquanto isso para nao sair cupom em dobro
  async reimprimirNota(nota, btn) {
    if (btn) btn.disabled = true;
    try {
      const resp = await Bridge.reimprimirCupom(nota.cupomId);
      // Bridge.call ja mostra o Toast quando da' erro
      if (resp && resp.sucesso) {
        Toast.success(resp.mensagem || 'Cupom enviado para a impressora');
      }
    } finally {
      if (btn) btn.disabled = false;
    }
  },

  async cancelarNota(nota) {
    const just = await Dialog.prompt(
      'Cancelar NFCe ' + nota.numNota,
      `Valor R$ ${Utils.formatMoney(nota.valor)}. O cartao da venda sera estornado. ` +
      'Informe o motivo (15 a 255 caracteres):',
      'Justificativa', '', false
    );
    if (just === null) return;

    const texto = String(just).trim();
    if (texto.length < 15) {
      Toast.warning('A justificativa deve ter pelo menos 15 caracteres');
      return;
    }

    // Reusa o fluxo de autorizacao do PDV: o backend responde
    // requerAutorizacao e aqui se pede matricula + senha do supervisor.
    const resp = await POS._executarComAutorizacao(aut =>
      Bridge.cancelarNFCe(nota.cupomId, texto, aut));

    if (resp && resp.sucesso) {
      Toast.success(resp.mensagem || 'NFCe cancelada');
      await this.carregarCancelaveis();
      await TEFAdm.carregarTransacoes();
    } else if (resp && !(resp.dados && resp.dados.requerAutorizacao)) {
      Toast.error(resp.mensagem || 'Falha ao cancelar a NFCe');
    }
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

      // So' rejeitado pode ser descartado: pendente ainda tem envio a fazer,
      // e tirar da fila perderia a nota. Por isso a linha sai sem checkbox.
      const podeDescartar = doc.status === 'REJEITADO';
      // Duplicidade e a unica rejeicao que NAO pode ser regerada: o numero ja
      // esta autorizado na SEFAZ e uma nota nova viraria uma segunda venda.
      // No "Regerar" ela so' e' conferida pela chave (ver RegerarDoc).
      const duplicidade = /duplicidade/i.test(doc.ultimoErro || '');
      const check = podeDescartar
        ? `<input type="checkbox" class="nfce-sel" value="${doc.id}" data-valor="${doc.valorVenda}" data-nota="${doc.numNota}" data-dup="${duplicidade ? 1 : 0}">`
        : '';

      tr.innerHTML = `
        <td class="col-sel">${check}</td>
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
      tbody.innerHTML = '<tr><td colspan="8" style="text-align:center; color: var(--text-muted); padding: 20px;">Nenhum documento pendente</td></tr>';
    }

    tbody.querySelectorAll('.nfce-sel').forEach(cb => {
      cb.addEventListener('change', () => this._atualizarSelecao());
    });
    document.getElementById('nfce-sel-todos').checked = false;
    this._atualizarSelecao();
  },

  _selecionados() {
    return Array.from(document.querySelectorAll('#nfce-pendentes-tbody .nfce-sel:checked'));
  },

  // O botao mostra quanto vai sair da fila: sem isso o operador clica no escuro
  _atualizarSelecao() {
    const marcados = this._selecionados();
    const btn = document.getElementById('btn-descartar-pend');
    btn.disabled = marcados.length === 0;
    btn.textContent = marcados.length === 0
      ? 'Descartar Selecionados'
      : `Descartar Selecionados (${marcados.length})`;

    // Duplicidade tambem entra: o Delphi so' confere a chave na SEFAZ, nao regera
    const btnReg = document.getElementById('btn-regerar-pend');
    btnReg.disabled = marcados.length === 0;
    btnReg.textContent = marcados.length === 0
      ? 'Regerar Selecionadas'
      : `Regerar Selecionadas (${marcados.length})`;

    const todos = document.querySelectorAll('#nfce-pendentes-tbody .nfce-sel');
    const chkTodos = document.getElementById('nfce-sel-todos');
    chkTodos.checked = todos.length > 0 && marcados.length === todos.length;
    chkTodos.indeterminate = marcados.length > 0 && marcados.length < todos.length;
  },

  marcarTodos(marcar) {
    document.querySelectorAll('#nfce-pendentes-tbody .nfce-sel')
      .forEach(cb => { cb.checked = marcar; });
    this._atualizarSelecao();
  },

  // Nota rejeitada nao consome numeracao na SEFAZ: da para montar a nota de
  // novo com o MESMO numero. E o unico caminho quando a rejeicao foi de
  // conteudo (total/troco), porque retransmitir manda de volta o XML que ja
  // foi negado.
  async regerarSelecionadas() {
    const marcados = this._selecionados();
    const regeraveis = marcados.filter(cb => cb.dataset.dup !== '1');
    const duplicadas = marcados.filter(cb => cb.dataset.dup === '1');

    if (marcados.length === 0) {
      Toast.warning('Marque ao menos um documento rejeitado');
      return;
    }

    let texto = '';
    if (regeraveis.length > 0) {
      const notas = regeraveis.map(cb => cb.dataset.nota).join(', ');
      const total = regeraveis.reduce((s, cb) => s + (parseFloat(cb.dataset.valor) || 0), 0);
      texto += `As notas ${notas} (${Utils.formatMoney(total)}) serao montadas ` +
        'de novo a partir do cupom, com o mesmo numero e uma chave nova, e ' +
        'transmitidas a SEFAZ. A nota rejeitada nao consome numeracao, entao ' +
        'nada e perdido. ';
    }
    // Duplicidade nunca e' regerada (viraria uma segunda venda): a chave e'
    // consultada na SEFAZ e, se ja estiver autorizada, passa a AUTORIZADO
    if (duplicadas.length > 0) {
      const notasDup = duplicadas.map(cb => cb.dataset.nota).join(', ');
      texto += `As notas ${notasDup} (duplicidade) NAO serao regeradas: a chave ` +
        'sera consultada na SEFAZ e, se ja estiver autorizada, a nota passa a ' +
        'AUTORIZADO. ';
    }
    texto += 'Confirma?';

    const ok = await Dialog.confirm('Regerar NFCe', texto);
    if (!ok) return;

    const ids = marcados.map(cb => parseInt(cb.value, 10));
    const resp = await Bridge.regerarNFCeRejeitadas(ids);
    if (!resp) return;

    if (resp.sucesso) Toast.success(resp.mensagem);
    else Toast.error(resp.mensagem);

    await this.carregarPendentes();
  },

  // Descarte nao fala com a SEFAZ: rejeitado nunca foi autorizado, entao nao ha
  // cancelamento a pedir. O documento so' para de aparecer na fila.
  async descartarSelecionados() {
    const marcados = this._selecionados();
    if (marcados.length === 0) {
      Toast.warning('Marque ao menos um documento rejeitado');
      return;
    }

    const total = marcados.reduce((s, cb) => s + (parseFloat(cb.dataset.valor) || 0), 0);
    const ok = await Dialog.confirm('Descartar Documentos',
      `${marcados.length} documento(s) rejeitado(s), somando ${Utils.formatMoney(total)}, ` +
      'sairao da fila e nao serao mais transmitidos. Isso NAO cancela nada na ' +
      'SEFAZ: documento rejeitado nunca chegou a ser autorizado. O registro ' +
      'continua no banco, marcado como DESCARTADO. Confirma?');
    if (!ok) return;

    const ids = marcados.map(cb => parseInt(cb.value, 10));
    const resp = await Bridge.descartarNFCePendentes(ids);
    if (!resp) return;

    if (resp.sucesso) Toast.success(resp.mensagem);
    else Toast.error(resp.mensagem);

    await this.carregarPendentes();
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
    if (!resp) return;

    // Mostrar a mensagem real do Delphi: "parcial - N enviado(s), M erro(s)"
    // e' o que diz se ainda ha nota travada
    if (resp.sucesso) {
      const houveErro = resp.dados && resp.dados.erros > 0;
      if (houveErro) Toast.warning(resp.mensagem);
      else Toast.success(resp.mensagem);
    } else {
      Toast.error(resp.mensagem);
    }

    await this.carregarPendentes();
    await this.atualizarStatusConexao();
  }
};

/* ========================================================
   Logotipo da loja - impresso no DANFCe gerado em PDF.
   O DANFCe (TACBrNFCeDANFeFPDF) exige PNG, entao qualquer imagem escolhida
   e' convertida e redimensionada aqui antes de ir para o Delphi.
   ======================================================== */
const Logo = {
  LARGURA_MAXIMA: 400,
  _pendente: null, // data URL PNG aguardando "Salvar"

  init() {
    document.getElementById('logo-arquivo')
      .addEventListener('change', (e) => this.selecionar(e.target.files[0]));
    document.getElementById('btn-logo-salvar')
      .addEventListener('click', () => this.salvar());
    document.getElementById('btn-logo-remover')
      .addEventListener('click', () => this.remover());
  },

  async carregar() {
    const resp = await Bridge.obterLogo();
    if (!resp || !resp.sucesso) return;

    const d = resp.dados;
    this._pendente = null;
    document.getElementById('logo-arquivo').value = '';
    document.getElementById('btn-logo-salvar').disabled = true;

    if (d.existe && d.dataUrl) {
      this._mostrarPreview(d.dataUrl);
      this._info(`Atual: ${Math.round(d.tamanhoBytes / 1024)} KB - alterado em ${d.modificadoEm}`);
    } else if (d.existe) {
      this._mostrarPreview(null);
      this._info(`Logotipo configurado (${Math.round(d.tamanhoBytes / 1024)} KB), grande demais para pre-visualizar`);
    } else {
      this._mostrarPreview(null);
      this._info('O arquivo sera gravado em ' + d.arquivo);
    }

    // O mesmo logo do cupom aparece no header e no protetor de tela
    const dataUrl = d.existe ? (d.dataUrl || '') : '';
    this.aplicarNoHeader(dataUrl);
    if (typeof Screensaver !== 'undefined') Screensaver.definirLogo(dataUrl);

    document.getElementById('btn-logo-remover').disabled = !d.existe;
  },

  // Troca o nome do sistema pelo logotipo da loja no header do PDV.
  // Sem logo (ou grande demais para trafegar), mantem o texto "ApoloWeb".
  aplicarNoHeader(dataUrl) {
    const img = document.getElementById('pos-logo-img');
    const texto = document.getElementById('pos-logo-texto');
    if (!img || !texto) return;

    if (dataUrl) {
      img.src = dataUrl;
      img.classList.remove('hidden');
      texto.classList.add('hidden');
    } else {
      img.removeAttribute('src');
      img.classList.add('hidden');
      texto.classList.remove('hidden');
    }
  },

  async selecionar(file) {
    if (!file) return;

    try {
      this._pendente = await this._converterParaPNG(file);
    } catch (err) {
      Toast.error('Nao foi possivel ler a imagem: ' + err.message);
      return;
    }

    this._mostrarPreview(this._pendente);
    const kb = Math.round((this._pendente.length * 3 / 4) / 1024);
    this._info(`Novo logotipo pronto (${kb} KB). Clique em Salvar para aplicar.`);
    document.getElementById('btn-logo-salvar').disabled = false;
  },

  // Desenha a imagem num canvas e exporta PNG: normaliza o formato e limita a
  // largura, para nao inflar o PDF do cupom.
  _converterParaPNG(file) {
    return new Promise((resolve, reject) => {
      const reader = new FileReader();
      reader.onerror = () => reject(new Error('falha na leitura do arquivo'));
      reader.onload = () => {
        const img = new Image();
        img.onerror = () => reject(new Error('formato de imagem nao suportado'));
        img.onload = () => {
          const escala = Math.min(1, this.LARGURA_MAXIMA / img.width);
          const canvas = document.createElement('canvas');
          canvas.width = Math.max(1, Math.round(img.width * escala));
          canvas.height = Math.max(1, Math.round(img.height * escala));
          canvas.getContext('2d').drawImage(img, 0, 0, canvas.width, canvas.height);
          resolve(canvas.toDataURL('image/png'));
        };
        img.src = reader.result;
      };
      reader.readAsDataURL(file);
    });
  },

  async salvar() {
    if (!this._pendente) { Toast.warning('Escolha uma imagem primeiro'); return; }

    const resp = await Bridge.salvarLogo(this._pendente);
    if (resp && resp.sucesso) {
      Toast.success(resp.mensagem);
      await this.carregar();
    }
  },

  async remover() {
    const ok = await Dialog.confirm('Remover Logotipo',
      'Os proximos cupons serao impressos sem o logotipo. Confirma?');
    if (!ok) return;

    const resp = await Bridge.removerLogo();
    if (resp && resp.sucesso) {
      Toast.success(resp.mensagem);
      await this.carregar();
    }
  },

  _mostrarPreview(dataUrl) {
    const img = document.getElementById('logo-preview');
    const vazio = document.getElementById('logo-vazio');
    if (dataUrl) {
      img.src = dataUrl;
      img.classList.remove('hidden');
      vazio.classList.add('hidden');
    } else {
      img.removeAttribute('src');
      img.classList.add('hidden');
      vazio.classList.remove('hidden');
    }
  },

  _info(texto) {
    document.getElementById('logo-info').textContent = texto;
  }
};

/* ========================================================
   Parametros do TEF (aba TEF)
   Grava na secao [TEF] do apoloweb.ini e recria o cliente
   no Delphi na hora, sem reiniciar o caixa.
   ======================================================== */

const TEFConfig = {
  init() {
    document.getElementById('tef-modo')
      .addEventListener('change', () => this._aplicarModo());
    document.getElementById('tef-pix-qr')
      .addEventListener('change', () => this._aplicarModo());
    document.getElementById('btn-tef-salvar')
      .addEventListener('click', () => this.salvar());
    document.getElementById('btn-tef-testar')
      .addEventListener('click', () => this.testar());
    document.getElementById('btn-tef-recarregar')
      .addEventListener('click', () => this.carregar());
    // Outra DLL = outra pasta de kit: mostra os arquivos dela
    document.getElementById('tef-sitef-dll')
      .addEventListener('change', () => this.carregarKit());
  },

  async carregar() {
    const resp = await Bridge.obterParametrosTEF();
    if (!resp || !resp.sucesso) return;

    const d = resp.dados;
    document.getElementById('tef-habilitado').checked = !!d.habilitado;
    document.getElementById('tef-modo').value = d.modo || 'http';
    document.getElementById('tef-url').value = d.url || '';
    document.getElementById('tef-pasta-req').value = d.pastaReq || '';
    document.getElementById('tef-pasta-resp').value = d.pastaResp || '';
    document.getElementById('tef-timeout').value = d.timeout || 120;
    document.getElementById('tef-debug').checked = !!d.debug;
    document.getElementById('tef-pix-qr').value = d.pixQr || 'pinpad';
    document.getElementById('tef-pix-qr-campos').value = d.pixQrCampos || 'auto';
    document.getElementById('tef-pix-qr-chaves').value = d.pixQrChaves || 'auto';
    document.getElementById('tef-sitef-dll').value = d.sitefDll || '';
    document.getElementById('tef-sitef-ip').value = d.sitefIp || '';
    document.getElementById('tef-sitef-loja').value = d.sitefLoja || '';
    document.getElementById('tef-sitef-terminal').value = d.sitefTerminal || '';
    document.getElementById('tef-sitef-param').value = d.sitefParamAdic || '';
    this._mostrarKit(d.kit);

    this._aplicarModo();
    this._status(d.ativo
      ? `Ativo no caixa ${d.numCaixa}: ${d.descricao}`
      : `TEF desligado. As alteracoes vao para ${d.arquivoIni}`);
  },

  // So mostra os campos do modo escolhido: url no http, pastas no arquivo,
  // DLL/loja/terminal no clisitef. Os campos/chaves do BR Code so interessam
  // com o QR na tela.
  _aplicarModo() {
    const modo = document.getElementById('tef-modo').value;
    document.querySelectorAll('#nfce-tef .tef-so-http')
      .forEach(el => el.classList.toggle('hidden', modo !== 'http'));
    document.querySelectorAll('#nfce-tef .tef-so-arquivo')
      .forEach(el => el.classList.toggle('hidden', modo !== 'arquivo'));
    document.querySelectorAll('#nfce-tef .tef-so-clisitef')
      .forEach(el => el.classList.toggle('hidden', modo !== 'clisitef'));

    const qrTela = document.getElementById('tef-pix-qr').value === 'tela';
    document.querySelectorAll('#nfce-tef .tef-so-qr-tela')
      .forEach(el => el.classList.toggle('hidden', !qrTela));
  },

  _dados() {
    return {
      habilitado: document.getElementById('tef-habilitado').checked,
      modo: document.getElementById('tef-modo').value,
      url: document.getElementById('tef-url').value.trim(),
      pastaReq: document.getElementById('tef-pasta-req').value.trim(),
      pastaResp: document.getElementById('tef-pasta-resp').value.trim(),
      timeout: parseInt(document.getElementById('tef-timeout').value, 10) || 120,
      debug: document.getElementById('tef-debug').checked,
      pixQr: document.getElementById('tef-pix-qr').value,
      pixQrCampos: document.getElementById('tef-pix-qr-campos').value.trim() || 'auto',
      pixQrChaves: document.getElementById('tef-pix-qr-chaves').value.trim() || 'auto',
      sitefDll: document.getElementById('tef-sitef-dll').value.trim(),
      sitefIp: document.getElementById('tef-sitef-ip').value.trim(),
      sitefLoja: document.getElementById('tef-sitef-loja').value.trim(),
      sitefTerminal: document.getElementById('tef-sitef-terminal').value.trim(),
      sitefParamAdic: document.getElementById('tef-sitef-param').value.trim()
    };
  },

  async salvar() {
    const dados = this._dados();
    const clisitef = dados.modo === 'clisitef';
    // Token errado barra antes de gravar qualquer coisa
    if (clisitef && !this._tokenValido()) return;

    const resp = await Bridge.salvarParametrosTEF(dados);
    if (!resp) return;

    // Bridge.call ja mostra o Toast de erro; aqui so fixa o motivo na tela
    if (!resp.sucesso) {
      this._status(resp.mensagem, true);
      return;
    }

    // clisitef: porta do pinpad, trace e TLS vao para os arquivos do kit
    if (clisitef && !(await this.salvarKit())) return;

    Toast.success(resp.mensagem);
    await this.carregar();
  },

  async testar() {
    this._status('Testando...');
    const resp = await Bridge.testarTEF(this._dados());
    if (!resp) { this._status('Falha na comunicacao com o PDV', true); return; }

    if (!resp.sucesso) {
      this._status(resp.mensagem, true);
      return;
    }

    const online = resp.dados && resp.dados.online;
    const texto = `${online ? 'OK' : 'SEM RESPOSTA'} - ${resp.dados.descricao}`;
    this._status(texto, !online);
    if (online) Toast.success('Gerenciador TEF respondeu');
    else Toast.warning('Gerenciador TEF nao respondeu');
  },

  // ---------- Kit CliSiTef (CliSiTef.ini / CONFITLS.INI) ----------

  async carregarKit() {
    const dll = document.getElementById('tef-sitef-dll').value.trim();
    const resp = await Bridge.lerKitCliSiTef(dll);
    if (resp && resp.sucesso) this._mostrarKit(resp.dados);
  },

  _mostrarKit(k) {
    const el = document.getElementById('tef-kit-status');
    if (!k) { el.textContent = ''; return; }

    const partes = [];
    if (!k.dllExiste) partes.push('DLL nao encontrada');
    else partes.push(k.versao || 'CliSiTef32I.dll');
    partes.push(k.iniExiste ? 'CliSiTef.ini ok' : 'sem CliSiTef.ini');
    if (k.tlsExiste) {
      partes.push('CONFITLS.INI ok' + (k.tokenConfigurado ? ', token configurado' : ', SEM token'));
    } else {
      partes.push('sem CONFITLS.INI');
    }
    el.textContent = (k.pasta ? k.pasta + ' - ' : '') + partes.join(' | ');
    el.classList.toggle('cfg-status-erro', !k.dllExiste || (k.tlsExiste && !k.tokenConfigurado));

    document.getElementById('tef-kit-porta').value = k.portaPinPad || '';
    document.getElementById('tef-kit-trace').checked = !!k.trace;
    document.getElementById('tef-kit-tls-url').value = k.tlsUrl || '';
    const token = document.getElementById('tef-kit-token');
    token.value = '';
    token.placeholder = k.tokenConfigurado
      ? 'configurado - deixe em branco para manter'
      : '0000-0000-0000-0000';
  },

  _tokenValido() {
    const token = document.getElementById('tef-kit-token').value.trim();
    if (token && !/^\d{4}-\d{4}-\d{4}-\d{4}$/.test(token)) {
      Toast.warning('O token deve ter o formato 0000-0000-0000-0000');
      return false;
    }
    return true;
  },

  // Devolve true se gravou
  async salvarKit() {
    if (!this._tokenValido()) return false;
    const token = document.getElementById('tef-kit-token').value.trim();
    const resp = await Bridge.salvarKitCliSiTef({
      dll: document.getElementById('tef-sitef-dll').value.trim(),
      portaPinPad: document.getElementById('tef-kit-porta').value.trim(),
      trace: document.getElementById('tef-kit-trace').checked,
      tlsUrl: document.getElementById('tef-kit-tls-url').value.trim(),
      token: token
    });
    if (!resp) return false;
    if (resp.sucesso) {
      this._mostrarKit(resp.dados);
      return true;
    }
    document.getElementById('tef-kit-status').textContent = resp.mensagem;
    document.getElementById('tef-kit-status').classList.add('cfg-status-erro');
    return false;
  },

  _status(texto, erro = false) {
    const el = document.getElementById('tef-status');
    el.textContent = texto;
    el.classList.toggle('cfg-status-erro', !!erro);
  }
};

/* ========================================================
   TEF administrativo (parte de baixo da aba TEF)
   Menu ADM do gerenciador, status do pinpad, estorno (CNC)
   e reimpressao de comprovante.
   ======================================================== */

const TEFAdm = {
  init() {
    document.getElementById('btn-tef-adm')
      .addEventListener('click', () => this.abrirMenu());
    document.getElementById('btn-tef-status')
      .addEventListener('click', () => this.consultarStatus());
    document.getElementById('btn-tef-transacoes')
      .addEventListener('click', () => this.carregarTransacoes());
  },

  // O ADM devolve o controle so quando o operador sai do menu do gerenciador,
  // por isso o resultado chega depois, por 'tefAdmResultado'.
  async abrirMenu() {
    // clisitef: nao ha gerenciador - o menu do SiTef vem para a tela do PDV
    this._status(Payment._tefInterativo
      ? 'Menu administrativo do SiTef aberto. Siga as opcoes na tela...'
      : 'Menu administrativo aberto no gerenciador. Conclua a operacao na tela dele...');
    const resp = await Bridge.administracaoTEF();
    if (!resp || !resp.sucesso) {
      this._status(resp ? resp.mensagem : 'Falha ao abrir o menu administrativo', true);
      Toast.error(resp ? resp.mensagem : 'Falha ao abrir o menu administrativo');
    }
  },

  onResultadoAdm(data) {
    if (data.sucesso) {
      this._status('Operacao administrativa concluida.');
      Toast.success('Operacao administrativa concluida');
      return;
    }

    // Sair do menu sem concluir nada e o caminho normal de quem so foi
    // consultar: informa, mas nao pinta de vermelho como se fosse falha.
    if (data.status === 'CANCELADA') {
      this._status('Menu administrativo encerrado sem operacao.');
      Toast.info('Menu administrativo encerrado');
      return;
    }

    const erro = data.erro || 'Operacao administrativa nao concluida';
    this._status(erro, true);
    Toast.error(erro);
  },

  async consultarStatus() {
    const resp = await Bridge.consultarStatusTEF();
    if (!resp || !resp.sucesso) {
      this._status(resp ? resp.mensagem : 'TEF indisponivel', true);
      return;
    }
    const online = resp.dados && resp.dados.online;
    this._status(online ? 'Gerenciador TEF no ar' : 'Gerenciador TEF nao respondeu', !online);
    if (online) Toast.success('Gerenciador TEF no ar');
    else Toast.warning('Gerenciador TEF nao respondeu');
  },

  async carregarTransacoes() {
    const resp = await Bridge.listarTransacoesTEF();
    const tbody = document.getElementById('tef-transacoes-tbody');
    if (!tbody) return;
    tbody.innerHTML = '';

    if (!resp || !resp.sucesso || !resp.dados || resp.dados.length === 0) {
      tbody.innerHTML = '<tr><td colspan="8" style="text-align:center; color: var(--text-muted); padding: 20px;">Nenhuma transacao TEF hoje</td></tr>';
      return;
    }

    resp.dados.forEach(t => {
      const estornada = t.status === 'ESTORNADO' || t.status === 'DESFEITO';
      const statusClass = estornada ? 'text-danger' :
                          t.status === 'CONFIRMADO' ? 'text-success' : 'text-warning';

      const acoes =
        (estornada ? '' : `<button class="btn btn-danger btn-sm" data-estornar="${t.id}">Estornar</button> `) +
        (t.temComprovante ? `<button class="btn btn-sm" data-reimprimir="${t.id}">2a via</button>` : '');

      const tr = document.createElement('tr');
      tr.innerHTML = `
        <td>${(t.dthrTransacao || '').substring(11, 16)}</td>
        <td>${t.numCupom || '-'}</td>
        <td>${(t.tipoTransacao || '').toUpperCase()}</td>
        <td>${t.bandeira || '-'}</td>
        <td style="font-family: var(--font-mono);">${t.nsu || '-'}</td>
        <td style="text-align:right; font-family: var(--font-mono);">${Utils.formatMoney(t.valor)}</td>
        <td class="${statusClass}">${t.status}</td>
        <td class="col-acao">${acoes}</td>
      `;

      const btnEst = tr.querySelector('[data-estornar]');
      if (btnEst) btnEst.addEventListener('click', () => this.estornar(t));
      const btnRe = tr.querySelector('[data-reimprimir]');
      if (btnRe) btnRe.addEventListener('click', () => this.reimprimir(t));
      tbody.appendChild(tr);
    });
  },

  async estornar(t) {
    const ok = await Dialog.prompt('Estornar transacao TEF',
      `NSU ${t.nsu} - R$ ${Utils.formatMoney(t.valor)} (${t.bandeira || 'sem bandeira'}). ` +
      'O valor volta para o cliente. Confirma?');
    if (!ok) return;

    const resp = await POS._executarComAutorizacao(aut => Bridge.estornarTEF(t.id, aut));
    if (resp && resp.sucesso)
      this._status('Estorno enviado ao gerenciador, aguarde a resposta do pinpad...');
    else if (resp && !(resp.dados && resp.dados.requerAutorizacao))
      Toast.error(resp.mensagem || 'Falha ao enviar o estorno');
  },

  onResultadoEstorno(data) {
    if (data.sucesso) {
      this._status('Transacao estornada (NSU ' + (data.nsu || '') + ').');
      Toast.success('Transacao TEF estornada');
    } else {
      const erro = data.erro || 'O gerenciador nao confirmou o estorno';
      this._status(erro, true);
      Toast.error('Estorno nao concluido: ' + erro);
    }
    this.carregarTransacoes();
  },

  async reimprimir(t) {
    const resp = await Bridge.reimprimirComprovanteTEF(t.id);
    if (resp && resp.sucesso) Toast.success('Comprovante enviado para a impressora');
    else Toast.error(resp ? resp.mensagem : 'Falha ao reimprimir');
  },

  _status(texto, erro = false) {
    const el = document.getElementById('tef-adm-status');
    if (!el) return;
    el.textContent = texto;
    el.classList.toggle('cfg-status-erro', !!erro);
  }
};

/* ========================================================
   Impressora do cupom (aba Impressora)
   Grava na secao [impressao] do apoloweb.ini e reaplica no
   ACBr na hora, sem reiniciar o caixa.
   ======================================================== */

const ImpressoraConfig = {
  _salvo: null, // ultimo estado gravado, para detectar alteracao pendente

  init() {
    document.getElementById('imp-modo')
      .addEventListener('change', () => this._aplicarModo());
    document.getElementById('btn-imp-salvar')
      .addEventListener('click', () => this.salvar());
    document.getElementById('btn-imp-testar')
      .addEventListener('click', () => this.testar());
    document.getElementById('btn-imp-recarregar')
      .addEventListener('click', () => this.carregar());
  },

  async carregar() {
    const resp = await Bridge.obterParametrosImpressora();
    if (!resp || !resp.sucesso) return;

    const d = resp.dados;

    // Impressoras instaladas; a opcao vazia usa a padrao do Windows
    const sel = document.getElementById('imp-impressora');
    sel.innerHTML = '';
    sel.appendChild(new Option('(padrao do Windows)', ''));
    (d.impressoras || []).forEach(nome => sel.appendChild(new Option(nome, nome)));
    // Impressora do ini que nao existe mais nesta maquina: mantem visivel para
    // o operador enxergar o que esta configurado antes de trocar
    if (d.impressora && !(d.impressoras || []).includes(d.impressora)) {
      sel.appendChild(new Option(d.impressora + ' (nao instalada)', d.impressora));
    }
    sel.value = d.impressora || '';

    const selModelo = document.getElementById('imp-escpos-modelo');
    selModelo.innerHTML = '';
    (d.escposModelos || []).forEach(m => selModelo.appendChild(new Option(m, m)));
    selModelo.value = d.escposModelo || 'ppEscPosEpson';

    document.getElementById('imp-modo').value = d.modo || 'SUMATRA';
    document.getElementById('imp-escpos-porta').value = d.escposPorta || '';
    document.getElementById('imp-escpos-colunas').value = d.escposColunas || 48;

    document.getElementById('imp-impressora-hint').textContent =
      d.impressoraPadrao ? `Padrao do Windows: ${d.impressoraPadrao}` : 'Nenhuma impressora instalada';

    this._aplicarModo();
    this._salvo = JSON.stringify(this._dados());

    if (d.modo === 'SUMATRA' && !d.temSumatra) {
      this._status(!d.temPrintCupon
        ? 'SumatraPDF.exe e PrintCupon.exe nao encontrados - o cupom nao sera impresso'
        : 'SumatraPDF.exe nao encontrado - vai usar o PrintCupon.exe', true);
    } else {
      this._status(`Gravado em ${d.arquivoIni}`);
    }
  },

  _aplicarModo() {
    const escpos = document.getElementById('imp-modo').value === 'ESCPOS';
    document.querySelectorAll('#nfce-impressora .imp-so-escpos')
      .forEach(el => el.classList.toggle('hidden', !escpos));
  },

  _dados() {
    return {
      modo: document.getElementById('imp-modo').value,
      impressora: document.getElementById('imp-impressora').value,
      escposModelo: document.getElementById('imp-escpos-modelo').value,
      escposPorta: document.getElementById('imp-escpos-porta').value.trim(),
      escposColunas: parseInt(document.getElementById('imp-escpos-colunas').value, 10) || 48
    };
  },

  _alterado() {
    return this._salvo !== JSON.stringify(this._dados());
  },

  async salvar() {
    const resp = await Bridge.salvarParametrosImpressora(this._dados());
    if (!resp) return false;

    if (resp.sucesso) {
      Toast.success(resp.mensagem);
      await this.carregar();
      return true;
    }
    this._status(resp.mensagem, true);
    return false;
  },

  // O teste sai com a configuracao ja aplicada no ACBr, entao alteracao
  // pendente precisa ser salva antes - senao o papel sairia com a config velha
  async testar() {
    if (this._alterado()) {
      const ok = await Dialog.confirm('Salvar antes de testar',
        'Ha alteracoes nao salvas. O teste usa a configuracao aplicada. ' +
        'Salvar agora e imprimir?');
      if (!ok) return;
      if (!await this.salvar()) return;
    }

    this._status('Enviando cupom de teste...');
    const resp = await Bridge.testarImpressao();
    if (!resp) { this._status('Falha na comunicacao com o PDV', true); return; }

    if (resp.sucesso) {
      Toast.success(resp.mensagem);
      this._status(`Teste enviado (modo ${resp.dados.modo})`);
    } else {
      this._status(resp.mensagem, true);
    }
  },

  _status(texto, erro = false) {
    const el = document.getElementById('imp-status');
    el.textContent = texto;
    el.classList.toggle('cfg-status-erro', !!erro);
  }
};
