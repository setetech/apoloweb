unit uConstantesWeb;

interface

const
  // Versao do sistema
  VERSAO_SISTEMA = '1.0.0';
  NOME_SISTEMA = 'ApoloWeb';

  // Pastas principais
  PASTA_RAIZ = 'C:\Apolo\';
  PASTA_WEB = 'C:\Apolo\web\';
  PASTA_XML = 'C:\Apolo\XML\';
  PASTA_NFCE = 'C:\Apolo\NFC-e\';
  PASTA_BKP = 'C:\Apolo\BKP\';
  PASTA_DFE = 'C:\Apolo\XML\DFE\';
  PASTA_SCHEMAS = 'C:\Apolo\Schemas\';

  // Banco SQLite
  ARQUIVO_SQLITE = 'C:\Apolo\ApoloWeb.db';

  // Configuracao XML/INI
  ARQ_CONFIG_XML = 'C:\Apolo\Apolo.xml';
  ARQ_CONFIG_INI = 'C:\Apolo\Apolo.ini';

  // Permissoes de acesso (codigos de controle)
  PA_REG_PRODUTO              = 01;
  PA_APLICAR_DESCONTO_ITEM    = 02;
  PA_APLICAR_DESCONTO_PGTO    = 03;
  PA_CANCELAR_ITEM            = 04;
  PA_CANCELAR_CUPOM           = 05;
  PA_FECHAMENTO_CAIXA         = 06;
  PA_CADASTROS_BASICOS        = 07;
  PA_PARAMETROS_GERAIS        = 08;
  PA_PAGAMENTOS_PRAZO         = 09;
  PA_ABRIR_GAVETA             = 10;
  PA_AUTORIZAR_CHEQUE         = 11;
  PA_VISUALIZAR_RESUMO        = 12;
  PA_CREDITO_TROCA_DEVOLUCAO  = 13;
  PA_FUNCOES_TEF              = 14;
  PA_REIMPRIMIR_CUPOM         = 15;
  PA_EMITIR_SUPRIMENTO        = 16;
  PA_CONSULTAR_PRODUTO        = 17;
  PA_EFETUAR_SANGRIA          = 18;
  PA_ALTERAR_PRECO            = 19;

  // Estados do caixa
  ESTADO_LIVRE       = 0;
  ESTADO_REGISTRANDO = 1;
  ESTADO_PAGAMENTO   = 2;

  // Chaves do estado_caixa (SQLite)
  KEY_TOTAL_DINHEIRO   = 'TOTAL_DINHEIRO';
  KEY_NUMCUPOM         = 'NUMCUPOM';
  KEY_NUMCAIXA         = 'NUMCAIXA';
  KEY_NUMSERIE         = 'NUMSERIE';
  KEY_ESTADO           = 'ESTADO';
  KEY_NUMSEQ_FECHAM    = 'NUMSEQ_FECHAMENTO';
  KEY_DT_FECHAMENTO    = 'DT_FECHAMENTO';
  KEY_STRING_FECHAM    = 'STRING_FECHAMENTO';
  KEY_PROX_NUM_NOTA    = 'PROX_NUM_NOTA';
  KEY_PROX_NUM_CUPOM   = 'PROX_NUM_CUPOM';
  KEY_SERIE_NFCE       = 'SERIE_NFCE';
  KEY_OPERADOR         = 'OPERADOR';
  KEY_MATRICULA        = 'MATRICULA';
  KEY_CODFILIAL        = 'CODFILIAL';
  KEY_HD_SERIAL        = 'HD_SERIAL';
  KEY_CODCONSUMIDOR    = 'CODCONSUMIDOR';

  // Arquivos gerados a partir de BLOBs do Oracle
  ARQUIVO_CERTIFICADO = 'C:\Apolo\certificado.pfx';
  ARQUIVO_LOGO        = 'C:\Apolo\logo_nfce.png';

  // Registro Windows - Secoes (apenas conexao)
  REG_SEC_BROKER      = 'Broker';
  REG_SEC_WSORA       = 'wsOra';

  // Intervalo do monitor de conexao (ms)
  INTERVALO_MONITOR_CONEXAO = 60000; // 60 segundos
  MAX_TENTATIVAS_CONTINGENCIA = 3;
  INTERVALO_RETRY_SYNC = 300000; // 5 minutos
  INTERVALO_SYNC_AUTO  = 60000;  // 1 minuto - verificacao automatica

implementation

end.
