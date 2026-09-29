-- ============================================================================
-- ApoloWeb - objetos que a retaguarda precisa ter para receber as vendas
--
-- Diagnostico em 21/08/2026 no schema FERNANDES @ 82.39.244.20:7721/ORDOTY:
--   MSDOCELETRONICO ......... EXISTE (XML da NFCe ja sobe normalmente)
--   MSAPOLO_VENDA ........... NAO EXISTE
--   MSAPOLO_VENDA_ITEM ...... NAO EXISTE
--   MSAPOLO_VENDA_PAGTO ..... NAO EXISTE
--   MSLOG_CUPOM ............. NAO EXISTE
--   MSAPOLO_VENDA_SEQ ....... NAO EXISTE  -> ORA-02289 em todo upload de venda
--
-- Se a retaguarda ja tem o DDL oficial destes objetos, USE O DELE. Este script
-- e' derivado dos INSERT de uSincronizacao.pas (UploadVenda / UploadDocEletronico)
-- e serve como referencia do minimo que o PDV precisa encontrar la.
--
-- Tipos das colunas de data/hora: o PDV envia texto 'YYYY-MM-DD HH24:MI:SS'
-- (ParamByName(...).AsString, sem TO_DATE). Por isso estao como VARCHAR2 aqui.
-- Se a retaguarda precisar de DATE, e' preciso alterar tambem os INSERT em
-- uSincronizacao.pas para usar TO_DATE, senao o insert depende do NLS da sessao.
-- ============================================================================

CREATE SEQUENCE msapolo_venda_seq START WITH 1 INCREMENT BY 1 NOCACHE NOCYCLE;

-- ---------------------------------------------------------------- cabecalho
CREATE TABLE msapolo_venda (
  numtrans                    NUMBER(15)     NOT NULL,
  codfilial                   VARCHAR2(2),
  numcaixa                    NUMBER(5),
  numcupom                    NUMBER(10),
  codoper                     VARCHAR2(1),   -- 'V' venda, 'C' cancelada
  datamovto                   VARCHAR2(19),
  dthriniciovenda             VARCHAR2(19),
  dthrfimvenda                VARCHAR2(19),
  codoperador                 NUMBER(10),
  codsupervisor               NUMBER(10),
  codcli                      NUMBER(10),
  cpf_cnpj                    VARCHAR2(18),
  descnomecliente             VARCHAR2(60),
  qtdeitens                   NUMBER(10),
  valorvenda                  NUMBER(15,2),
  valordesc                   NUMBER(15,2),
  valorencargo                NUMBER(15,2),
  valortroco                  NUMBER(15,2),
  chavenfe                    VARCHAR2(60),  -- 44 digitos, sem o prefixo 'NFe'
  protocolo_nfe               VARCHAR2(30),
  numserieequip               VARCHAR2(30),
  versao                      VARCHAR2(20),
  tipo_contingencia           VARCHAR2(10),  -- NORMAL / OFFLINE / SVC_AN / ...
  dt_contingencia             VARCHAR2(19),
  contingencia_justificativa  VARCHAR2(256),
  CONSTRAINT pk_msapolo_venda PRIMARY KEY (numtrans)
);

CREATE INDEX msapolo_venda_idx01 ON msapolo_venda (codfilial, numcaixa, numcupom);
CREATE INDEX msapolo_venda_idx02 ON msapolo_venda (chavenfe);

-- -------------------------------------------------------------------- itens
CREATE TABLE msapolo_venda_item (
  numtrans      NUMBER(15)    NOT NULL,
  numseqitem    NUMBER(5)     NOT NULL,
  codprod       NUMBER(15),
  codbarra      VARCHAR2(20),
  descricao     VARCHAR2(80),
  unidade       VARCHAR2(5),
  qt            NUMBER(15,3),
  qtunit        NUMBER(15,3) DEFAULT 1,  -- qtde por embalagem do EAN bipado (informativo)
  punit         NUMBER(15,4),
  vlprod        NUMBER(15,2),  -- BRUTO (desconto vai em vldesconto)
  vldesconto    NUMBER(15,2),
  ncm           VARCHAR2(10),
  cfop          VARCHAR2(5),
  cest          VARCHAR2(10),
  icms_cst      VARCHAR2(5),
  csosn         VARCHAR2(5),
  aliqicms      NUMBER(9,4),
  pis_cst       VARCHAR2(5),
  cofins_cst    VARCHAR2(5),
  aliqpis       NUMBER(9,4),
  aliqcofins    NUMBER(9,4),
  codvendedor   NUMBER(10),
  dtcancel      VARCHAR2(19),
  obscancel     VARCHAR2(256),
  emoferta      VARCHAR2(1),
  ptabela       NUMBER(15,4),
  prod_origem   VARCHAR2(2),
  CONSTRAINT pk_msapolo_venda_item PRIMARY KEY (numtrans, numseqitem),
  CONSTRAINT fk_msapolo_venda_item FOREIGN KEY (numtrans)
    REFERENCES msapolo_venda (numtrans)
);

-- Instalacoes onde a tabela ja existe sem a coluna qtunit:
-- ALTER TABLE msapolo_venda_item ADD (qtunit NUMBER(15,3) DEFAULT 1);
-- (o PDV verifica a existencia da coluna e envia sem ela enquanto nao rodar)

-- --------------------------------------------------------------- pagamentos
CREATE TABLE msapolo_venda_pagto (
  numtrans          NUMBER(15)  NOT NULL,
  codcob            VARCHAR2(5),
  valor             NUMBER(15,2),
  numbanco          NUMBER(5),
  numagencia        VARCHAR2(10),
  numcontacorrente  VARCHAR2(20),
  numcheque         VARCHAR2(20),
  numcmc7           VARCHAR2(40),
  cpf_cnpj_cheque   VARCHAR2(18),
  dtpredatado       VARCHAR2(19),
  codtipotransacao  NUMBER(5),
  codmodotransacao  NUMBER(5),
  codbandeira       NUMBER(5),
  codrede           NUMBER(5),
  codautorizacao    VARCHAR2(30),
  nsu               VARCHAR2(30),
  numparcela        NUMBER(5),
  qtdeparcela       NUMBER(5),
  codplpag          NUMBER(10),
  dtvenc            VARCHAR2(19),
  CONSTRAINT fk_msapolo_venda_pagto FOREIGN KEY (numtrans)
    REFERENCES msapolo_venda (numtrans)
);

CREATE INDEX msapolo_venda_pagto_idx01 ON msapolo_venda_pagto (numtrans);

-- ------------------------------------------------- log do cupom (acessorio)
-- Recebe o XML do cupom montado por MontarXmlCupom, com o numtrans vindo de
-- SEQ_PROX_NUMTRANS_MOV (o mesmo gravado em msdoceletronico).
-- O PDV tolera a ausencia desta tabela: o upload fiscal nao para por causa dela.
CREATE TABLE mslog_cupom (
  numtrans  NUMBER(15) NOT NULL,
  conteudo  CLOB,
  CONSTRAINT pk_mslog_cupom PRIMARY KEY (numtrans)
);

COMMIT;
