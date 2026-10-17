/* ========================================================
   Apolo Menu - ponte com o Rust
   Mesmo contrato do bridge.js do ApoloWeb: {action, data, callbackId}
   vai pelo window.ipc.postMessage (wry); a resposta {sucesso, mensagem,
   dados} volta pelo window.__apoloResolve(callbackId, resposta).
   ======================================================== */

const Bridge = {
  _contador: 0,
  _pendentes: {},

  // Oracle lento ou fora do ar: o Rust desiste no timeout do ini e responde
  // com erro; este limite so' dispara se o processo travar de verdade.
  TIMEOUT_MS: 120000,

  send(action, data = {}) {
    return new Promise((resolve, reject) => {
      if (!(window.ipc && window.ipc.postMessage)) {
        resolve({ sucesso: false, mensagem: 'Ponte indisponivel (aberto fora do Apolo Menu)', dados: {} });
        return;
      }
      const callbackId = 'cb_' + (++this._contador);
      const timer = setTimeout(() => {
        delete this._pendentes[callbackId];
        reject(new Error('Sem resposta do Apolo Menu (' + action + ')'));
      }, this.TIMEOUT_MS);

      this._pendentes[callbackId] = (resposta) => {
        clearTimeout(timer);
        resolve(resposta);
      };
      window.ipc.postMessage(JSON.stringify({ action, data, callbackId }));
    });
  },

  _resolver(callbackId, resposta) {
    const cb = this._pendentes[callbackId];
    if (!cb) return;
    delete this._pendentes[callbackId];
    cb(resposta);
  },

  iniciar() { return this.send('iniciar'); },
  obterConfig() { return this.send('obterConfig'); },
  testarConexao(cfg) { return this.send('testarConexao', cfg); },
  salvarConfig(cfg) { return this.send('salvarConfig', cfg); },
  login(login, senha) { return this.send('login', { login, senha }); },
  logout() { return this.send('logout'); },
  listarRotinas() { return this.send('listarRotinas'); },
  executarRotina(codrotina) { return this.send('executarRotina', { codrotina }); },
  fecharApp() { return this.send('fecharApp'); }
};

window.__apoloResolve = (callbackId, resposta) => Bridge._resolver(callbackId, resposta);
