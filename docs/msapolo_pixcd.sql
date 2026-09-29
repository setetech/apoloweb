-- ============================================================================
-- msapolo_pixcd - Configuracao da cobranca PIX dinamica (API Pix) do PDV
--
-- Cadastrada na RETAGUARDA (uma linha por filial). O ApoloWeb sincroniza na
-- abertura/login para a tabela pixcd_config do SQLite e passa a usar o
-- ACBrPIXCD: a cobranca e criada no PSP na hora do pagamento, o QR exibido
-- e dinamico e a confirmacao do recebimento e AUTOMATICA (o PDV consulta o
-- PSP a cada 3s e registra o pagamento sozinho quando o status vira
-- CONCLUIDA, guardando o endToEndId).
--
-- Sem linha nesta tabela (ou ativo = 'N') o PDV continua no QR estatico
-- montado com msfilial.chave_pix + confirmacao manual do operador.
--
-- Valores aceitos em PSP (nao diferencia maiusculas/minusculas):
--   BB (ou BANCODOBRASIL), ITAU, SICOOB, SICREDI, BRADESCO, SANTANDER,
--   INTER, EFI (ou GERENCIANET), MERCADOPAGO, C6 (ou C6BANK), AILOS,
--   BANRISUL, PAGSEGURO, CIELO
--
-- Credenciais por PSP (geradas no internet banking PJ / portal do PSP):
--   - Todos (exceto MERCADOPAGO): client_id + client_secret
--   - BB ............ chave_extra = developer_application_key (portal BB DevPortal)
--   - MERCADOPAGO ... chave_extra = access_token (unico campo necessario)
--   - EFI ........... arq_pfx + senha_pfx (certificado .p12 baixado no painel)
--   - ITAU/SICOOB/SICREDI/INTER/SANTANDER/BRADESCO...
--                     arq_certificado (.crt/.pem) + arq_chave_privada (.key),
--                     ou arq_pfx + senha_pfx, conforme o banco entregar
--
-- Os arquivos de certificado sao CAMINHOS LOCAIS NO CAIXA (recomendado:
-- C:\Apolo\pix\). Copiar os arquivos para cada caixa antes de ativar.
--
-- ambiente: 1 = producao | 2 = teste/homologacao (sandbox do PSP)
-- expiracao_seg: validade da cobranca em segundos (padrao 300 = 5 min)
-- chave_pix: se NULL usa a msfilial.chave_pix da propria filial
-- ============================================================================

CREATE TABLE msapolo_pixcd (
  codfilial         VARCHAR2(4)   NOT NULL,
  psp               VARCHAR2(20)  NOT NULL,
  ambiente          NUMBER(1)     DEFAULT 2 NOT NULL,
  chave_pix         VARCHAR2(77),
  client_id         VARCHAR2(256),
  client_secret     VARCHAR2(256),
  chave_extra       VARCHAR2(512),
  arq_certificado   VARCHAR2(256),
  arq_chave_privada VARCHAR2(256),
  arq_pfx           VARCHAR2(256),
  senha_pfx         VARCHAR2(128),
  expiracao_seg     NUMBER(5)     DEFAULT 300,
  ativo             VARCHAR2(1)   DEFAULT 'S',
  CONSTRAINT pk_msapolo_pixcd PRIMARY KEY (codfilial)
);

COMMENT ON TABLE msapolo_pixcd IS
  'Config da cobranca PIX dinamica (API Pix / ACBrPIXCD) do PDV ApoloWeb';

-- Exemplo (Sicoob, homologacao):
-- INSERT INTO msapolo_pixcd (codfilial, psp, ambiente, client_id, client_secret,
--   arq_certificado, arq_chave_privada, expiracao_seg, ativo)
-- VALUES ('1', 'SICOOB', 2, 'meu-client-id', 'meu-client-secret',
--   'C:\Apolo\pix\sicoob.crt', 'C:\Apolo\pix\sicoob.key', 300, 'S');

-- Exemplo (Banco do Brasil, producao):
-- INSERT INTO msapolo_pixcd (codfilial, psp, ambiente, client_id, client_secret,
--   chave_extra, ativo)
-- VALUES ('1', 'BB', 1, 'client-id-bb', 'client-secret-bb',
--   'developer-application-key-bb', 'S');

-- Exemplo (Mercado Pago - so o access token):
-- INSERT INTO msapolo_pixcd (codfilial, psp, ambiente, chave_extra, ativo)
-- VALUES ('1', 'MERCADOPAGO', 1, 'APP_USR-000000-access-token', 'S');
