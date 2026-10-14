/* ========================================================
   ApoloWeb - TEF interativo ([TEF] modo=clisitef)

   A CliSiTef nao tem tela propria: as mensagens, os menus
   (credito a vista / parcelado ...), as perguntas sim/nao e
   as coletas (parcelas, CPF, data, NSU) chegam do Delphi pelo
   push 'tefInteracao' e a resposta volta por responderTEF.

   Eventos (data.tipo):
     mensagem  {visor: operador|cliente|todos|cabecalho, texto}
     menu      {id, titulo, opcoes: [{codigo, texto}]}
     simnao    {id, titulo}
     campo     {id, titulo, min, max, numerico, monetario, mascarado}
     aviso     {id, titulo}            (so "ok, li")
     fim       a funcao da CliSiTef terminou - fecha a tela

   Pergunta sem resposta, o Delphi espera ate o [TEF] timeout
   e cancela sozinho.
   ======================================================== */

const TEFInterativo = {
  _pergunta: null,   // pergunta no ar ({id, tipo, ...}) ou null
  _cancelando: false,

  init() {
    document.getElementById('btn-tefi-cancelar')
      .addEventListener('click', () => this.cancelar());
    document.getElementById('btn-tefi-voltar')
      .addEventListener('click', () => this.voltar());
    document.getElementById('btn-tefi-ok')
      .addEventListener('click', () => this.confirmar());

    // O Enter global e' entregue ao modal do topo (keyboard.js), inclusive
    // com o foco no campo de coleta - por isso nada de keydown no input
    Keyboard.register('modal_modal-tef-interacao', {
      'Escape': () => this.cancelar(),
      'Enter': () => this.confirmar(),
      'F2': () => this.voltar()
    });

    // Atalhos do menu (numero da opcao) e do sim/nao (S/N). Captura para
    // o digito nao cair no campo de codigo de barras atras do modal.
    document.addEventListener('keydown', (e) => this._tecla(e), true);
  },

  _aberto() {
    return Modal.isOpen('modal-tef-interacao');
  },

  _abrir() {
    if (!this._aberto()) Modal.open('modal-tef-interacao');
  },

  onEvento(data) {
    if (!data || !data.tipo) return;

    // A conversa com o pinpad pode passar do [TEF] timeout somando menus e
    // coletas: cada evento prova que o TEF esta vivo
    if (typeof Payment !== 'undefined' && Payment._reiniciarWatchdogTEF) {
      Payment._reiniciarWatchdogTEF();
    }

    switch (data.tipo) {
      case 'mensagem':
        this._mensagem(data);
        break;
      case 'menu':
      case 'simnao':
      case 'campo':
      case 'aviso':
        this._perguntar(data);
        break;
      case 'fim':
        this.fechar();
        break;
      default:
        console.log('tefInteracao nao tratado:', data);
    }
  },

  _mensagem(data) {
    const texto = data.texto || '';
    let el;
    if (data.visor === 'cliente') el = document.getElementById('tefi-cliente');
    else if (data.visor === 'cabecalho') el = document.getElementById('tefi-cabecalho');
    else el = document.getElementById('tefi-mensagem');
    el.textContent = texto;
    el.classList.toggle('hidden', texto === '');

    // Espelha no spinner da tela de pagamento (fica visivel atras do modal)
    if ((data.visor === 'operador' || data.visor === 'todos') && texto) {
      const sub = document.getElementById('tef-aguardando-sub');
      if (sub) sub.textContent = texto.replace(/\n/g, ' ');
    }

    if (texto) this._abrir();
  },

  _perguntar(data) {
    this._pergunta = data;
    this._cancelando = false;

    const titulo = document.getElementById('tefi-titulo');
    const opcoes = document.getElementById('tefi-opcoes');
    const grupo = document.getElementById('tefi-input-group');
    const input = document.getElementById('tefi-input');
    const btnOk = document.getElementById('btn-tefi-ok');
    const btnVoltar = document.getElementById('btn-tefi-voltar');

    titulo.textContent = data.titulo || '';
    titulo.classList.remove('hidden');
    opcoes.innerHTML = '';
    opcoes.classList.add('hidden');
    grupo.classList.add('hidden');
    document.getElementById('tefi-espera').classList.add('hidden');
    btnOk.classList.add('hidden');
    btnVoltar.classList.toggle('hidden', !(data.tipo === 'menu' || data.tipo === 'campo'));

    let foco = null;
    if (data.tipo === 'menu') {
      (data.opcoes || []).forEach((op) => {
        const b = this._botaoOpcao(op.codigo + ' - ' + op.texto, op.codigo);
        opcoes.appendChild(b);
        if (!foco) foco = b;
      });
      opcoes.classList.remove('hidden');
    } else if (data.tipo === 'simnao') {
      // CliSiTef: 0 = sim, 1 = nao
      foco = this._botaoOpcao('S - Sim', '0');
      opcoes.appendChild(foco);
      opcoes.appendChild(this._botaoOpcao('N - Nao', '1'));
      opcoes.classList.remove('hidden');
    } else if (data.tipo === 'campo') {
      input.value = '';
      input.type = data.mascarado ? 'password' : 'text';
      input.inputMode = (data.numerico || data.monetario) ? 'decimal' : 'text';
      if (data.max > 0) input.maxLength = data.max; else input.removeAttribute('maxlength');
      input.placeholder = data.monetario ? '0,00' : '';
      document.getElementById('tefi-input-hint').textContent = this._dicaTamanho(data);
      grupo.classList.remove('hidden');
      btnOk.classList.remove('hidden');
      foco = input;
    } else {
      // aviso: so confirmar a leitura
      btnOk.classList.remove('hidden');
      foco = btnOk;
    }

    this._abrir();
    if (foco) setTimeout(() => foco.focus(), 120);
  },

  _botaoOpcao(rotulo, valor) {
    const b = document.createElement('button');
    b.type = 'button';
    b.className = 'btn tefi-opcao';
    b.textContent = rotulo;
    b.dataset.valor = valor;
    b.addEventListener('click', () => this._responder('ok', valor));
    return b;
  },

  _dicaTamanho(p) {
    if (p.min > 0 && p.max > 0 && p.min === p.max) return p.min + ' caracteres';
    if (p.min > 0 && p.max > 0) return 'De ' + p.min + ' a ' + p.max + ' caracteres';
    if (p.max > 0) return 'Ate ' + p.max + ' caracteres';
    return '';
  },

  // Enter: responde a pergunta do jeito que ela pede
  confirmar() {
    const p = this._pergunta;
    if (!p) return;

    if (p.tipo === 'campo') {
      let valor = document.getElementById('tefi-input').value.trim();
      if (p.min > 0 && valor.length < p.min) {
        Toast.warning('Informe ao menos ' + p.min + ' caracteres');
        return;
      }
      if (p.monetario) valor = valor.replace(/\./g, ',');
      this._responder('ok', valor);
      return;
    }

    if (p.tipo === 'menu' || p.tipo === 'simnao') {
      // Enter na opcao com foco (o keyboard.js barra o clique nativo do Enter)
      const ativo = document.activeElement;
      if (ativo && ativo.classList.contains('tefi-opcao')) {
        this._responder('ok', ativo.dataset.valor);
      }
      return;
    }

    this._responder('ok', '');
  },

  voltar() {
    const p = this._pergunta;
    if (p && (p.tipo === 'menu' || p.tipo === 'campo')) this._responder('voltar', '');
  },

  // Com pergunta na tela, cancela a pergunta (a CliSiTef encerra a funcao).
  // Sem pergunta - pinpad esperando o cartao - pede a interrupcao.
  cancelar() {
    if (this._pergunta) {
      this._responder('cancelar', '');
      return;
    }
    if (this._cancelando) return;
    this._cancelando = true;
    document.getElementById('tefi-mensagem').textContent = 'Cancelando...';
    document.getElementById('tefi-mensagem').classList.remove('hidden');
    Bridge.responderTEF({ id: 0, acao: 'cancelar', valor: '' });
  },

  _responder(acao, valor) {
    const p = this._pergunta;
    if (!p) return;
    this._pergunta = null;
    this._modoEspera();
    Bridge.responderTEF({ id: p.id, acao: acao, valor: valor });
  },

  // Sem pergunta: so as mensagens e o spinner
  _modoEspera() {
    document.getElementById('tefi-titulo').classList.add('hidden');
    document.getElementById('tefi-opcoes').innerHTML = '';
    document.getElementById('tefi-opcoes').classList.add('hidden');
    document.getElementById('tefi-input-group').classList.add('hidden');
    document.getElementById('tefi-input').value = '';
    document.getElementById('btn-tefi-ok').classList.add('hidden');
    document.getElementById('btn-tefi-voltar').classList.add('hidden');
    document.getElementById('tefi-espera').classList.remove('hidden');
  },

  // 'fim' da CliSiTef ou resultado da operacao (rede de seguranca)
  fechar() {
    this._pergunta = null;
    this._cancelando = false;
    this._modoEspera();
    ['tefi-mensagem', 'tefi-cliente', 'tefi-cabecalho'].forEach((id) => {
      const el = document.getElementById(id);
      el.textContent = '';
      el.classList.add('hidden');
    });
    if (this._aberto()) Modal.close('modal-tef-interacao');
  },

  _tecla(e) {
    const p = this._pergunta;
    if (!p || !this._aberto()) return;
    if (p.tipo !== 'menu' && p.tipo !== 'simnao') return;

    const botoes = Array.from(document.querySelectorAll('#tefi-opcoes .tefi-opcao'));
    let alvo = null;
    if (p.tipo === 'simnao' && /^[sSnN]$/.test(e.key)) {
      alvo = botoes[/[sS]/.test(e.key) ? 0 : 1];
    } else if (p.tipo === 'menu' && /^[0-9]$/.test(e.key)) {
      alvo = botoes.find((b) => b.dataset.valor === e.key);
    } else if (e.key === 'ArrowDown' || e.key === 'ArrowUp') {
      const i = botoes.indexOf(document.activeElement);
      const n = botoes.length;
      if (n === 0) return;
      const prox = e.key === 'ArrowDown' ? (i + 1) % n : (i - 1 + n) % n;
      e.preventDefault();
      e.stopPropagation();
      botoes[prox].focus();
      return;
    }

    if (alvo) {
      e.preventDefault();
      e.stopPropagation();
      this._responder('ok', alvo.dataset.valor);
    }
  }
};
