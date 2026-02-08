/* ========================================================
   ApoloWeb - Utilidades
   ======================================================== */

const Utils = {
  // Formatar valor monetario
  formatMoney(value) {
    if (value === null || value === undefined) return '0,00';
    return Number(value).toFixed(2).replace('.', ',').replace(/\B(?=(\d{3})+(?!\d))/g, '.');
  },

  // Formatar valor monetario com R$
  formatCurrency(value) {
    return 'R$ ' + this.formatMoney(value);
  },

  // Parse de valor monetario (string BR -> float)
  parseMoney(str) {
    if (!str) return 0;
    return parseFloat(str.replace(/\./g, '').replace(',', '.')) || 0;
  },

  // Formatar data dd/mm/yyyy
  formatDate(dateStr) {
    if (!dateStr) return '';
    const d = new Date(dateStr);
    if (isNaN(d)) return dateStr;
    return d.toLocaleDateString('pt-BR');
  },

  // Formatar data e hora
  formatDateTime(dateStr) {
    if (!dateStr) return '';
    const d = new Date(dateStr);
    if (isNaN(d)) return dateStr;
    return d.toLocaleDateString('pt-BR') + ' ' + d.toLocaleTimeString('pt-BR', { hour: '2-digit', minute: '2-digit' });
  },

  // Relogio
  getCurrentTime() {
    const now = new Date();
    return now.toLocaleTimeString('pt-BR', { hour: '2-digit', minute: '2-digit', second: '2-digit' });
  },

  // Gerar ID unico
  generateId() {
    return Date.now().toString(36) + Math.random().toString(36).substr(2);
  },

  // Mascara de moeda no input
  applyCurrencyMask(input) {
    input.addEventListener('input', function (e) {
      if (this.dataset.masked === '0') return;
      let value = e.target.value.replace(/\D/g, '');
      value = (parseInt(value) / 100).toFixed(2);
      if (isNaN(value) || value === 'NaN') value = '0.00';
      e.target.value = value.replace('.', ',');
    });

    input.addEventListener('focus', function () {
      if (this.dataset.masked === '0') return;
      if (this.value === '0,00') this.value = '';
    });

    input.addEventListener('blur', function () {
      if (this.dataset.masked === '0') return;
      if (!this.value) this.value = '0,00';
    });
  },

  // Aplicar mascara em todos os inputs currency
  initCurrencyMasks() {
    document.querySelectorAll('.input-currency').forEach(input => {
      this.applyCurrencyMask(input);
    });
  },

  // Truncar texto
  truncate(str, len) {
    if (!str) return '';
    return str.length > len ? str.substring(0, len) + '...' : str;
  },

  // Debounce
  debounce(func, wait) {
    let timeout;
    return function (...args) {
      clearTimeout(timeout);
      timeout = setTimeout(() => func.apply(this, args), wait);
    };
  }
};
