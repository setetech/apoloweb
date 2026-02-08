/* ========================================================
   ApoloWeb - Modulo de Relatorios
   ======================================================== */

const Reports = {
  init() {
    document.getElementById('btn-fech-cancel').addEventListener('click', () => {
      Modal.close('modal-fechamento');
    });

    document.getElementById('btn-fech-confirm').addEventListener('click', () => {
      Modal.close('modal-fechamento');
      Toast.success('Caixa fechado com sucesso');
      // Voltar para tela de login
      ApoloApp.showView('view-login');
    });
  }
};
