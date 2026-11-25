-- ============================================================================
-- ApoloWeb - preenche VBC_NFE / VICMS_NFE do historico a partir do XML
-- da NFC-e gravado em MSDOCELETRONICO
--
-- CONTEXTO: desde o commit 66888f6 o PDV grava por item, em
-- MSAPOLO_VENDA_ITEM, o vBC e o vICMS EXATOS do XML da NFC-e (ja com o
-- desconto e o acrescimo do subtotal rateados entre os itens - ver
-- uNFCeWeb.PreencherItens). As vendas anteriores ficaram com 0 ou NULL.
-- Este script le o XML autorizado e completa:
--   * MSAPOLO_VENDA_ITEM ... venda do PDV
--   * MSMOV ................ itens da NF gerada pela MSAPOLO_GERAR_NF
--
-- DE ONDE VEM CADA COISA:
--   MSDOCELETRONICO.xml_nfe (CLOB) ... o arquivo XML do ACBr, como saiu da
--       pasta NFCe\autorizadas (uSincronizacao.UploadDocEletronico). tipo='P'
--       e' a nota; tipo='C' e' o evento de cancelamento (nao tem det).
--       O numtrans dela vem da SEQ_PROX_NUMTRANS_MOV e NAO aponta para a venda;
--       a ligacao e' pela CHAVENFE (44 digitos, igual nas duas tabelas).
--   MSAPOLO_VENDA.numtrans_erp ....... numtrans da MSNF/MSMOV gerada pela
--       MSAPOLO_GERAR_NF (docs/msapolo_gerar_nf.sql). NULL = venda ainda nao
--       virou NF; nesse caso so a MSAPOLO_VENDA_ITEM e' preenchida.
--
-- CASAMENTO DOS ITENS (o ponto delicado):
--   * No XML, det/@nItem e' 1, 2, 3... contando SO os itens NAO cancelados,
--     em ordem de numseqitem. Com item cancelado no cupom, nItem <> numseqitem.
--     Aqui o item ativo na posicao k (ordem de numseqitem, dtcancel NULL) casa
--     com o det de nItem = k, e o cProd do XML TEM que ser o codprod do item.
--   * Na MSMOV a MSAPOLO_GERAR_NF numera msmov.item do mesmo jeito (1, 2, 3...
--     so os ativos, ordem de numseqitem), entao msmov.item = nItem. Tambem
--     confere o codprod.
--   * Se qualquer item da venda nao bater (quantidade ou produto), a venda
--     inteira e' PULADA e listada - nao se chuta o casamento.
--
-- VALORES:
--   vBC/vICMS saem de det/imposto/ICMS/<grupo>/vBC e vICMS, qualquer que seja
--   o grupo (ICMS00, ICMS20, ICMS60, ICMSSN102...). Grupo sem a tag (CST 60,
--   isento, Simples Nacional, aliquota zero) grava 0. Item cancelado no cupom
--   nao esta no XML e grava 0.
--
-- IDEMPOTENTE: so mexe em coluna NULL ou 0. Valor ja preenchido (diferente de
-- zero) nunca e' sobrescrito, mesmo que diverja do XML - a conferencia do
-- passo 2 mostra esses casos como DIVERGE. Pode rodar quantas vezes quiser.
--
-- ATENCAO: a MSAPOLO_GERAR_NF de docs/msapolo_gerar_nf.sql (versao do repo)
-- ainda NAO copia vbc_nfe/vicms_nfe para a MSMOV. Enquanto isso nao mudar, as
-- NFs geradas depois deste script nascem com NULL e e' preciso roda-lo de novo
-- (ou acrescentar mov.vbc_nfe := reg.vbc_nfe; mov.vicms_nfe := reg.vicms_nfe;
-- na secao 4.5 da procedure).
--
-- >>> RODAR NO ORACLE DA RETAGUARDA, COM O USUARIO DONO DAS TABELAS
-- >>> (as checagens usam USER_TAB_COLUMNS). Nada e' commitado ate o passo 5.
-- ============================================================================


-- ---------------------------------------------------------------------------
-- 1) As colunas existem?
--    Esperado: 5 linhas (VBC_NFE e VICMS_NFE nas duas tabelas de item e
--    NUMTRANS_ERP na MSAPOLO_VENDA).
-- ---------------------------------------------------------------------------
SELECT table_name, column_name, data_type, data_precision, data_scale
  FROM user_tab_columns
 WHERE table_name  IN ('MSAPOLO_VENDA', 'MSAPOLO_VENDA_ITEM', 'MSMOV')
   AND column_name IN ('VBC_NFE', 'VICMS_NFE', 'NUMTRANS_ERP')
 ORDER BY table_name, column_name;

-- Faltando na MSMOV (o caso esperado: o PDV nunca criou essas colunas la):
-- ALTER TABLE msmov ADD (vbc_nfe NUMBER(15,2), vicms_nfe NUMBER(15,2));
--
-- Faltando na MSAPOLO_VENDA_ITEM (retaguarda que ainda nao recebeu o PDV novo;
-- o upload so passa a enviar as colunas depois que elas existirem):
-- ALTER TABLE msapolo_venda_item ADD (vbc_nfe NUMBER(15,2), vicms_nfe NUMBER(15,2));
--
-- Faltando NUMTRANS_ERP: a MSAPOLO_GERAR_NF nao foi instalada, nao ha MSMOV
-- vinda do PDV e o passo 3 so atualiza a MSAPOLO_VENDA_ITEM.


-- ---------------------------------------------------------------------------
-- 2) ANTES: conferencia item a item (nada e' alterado)
--
--    Filtros no "par": NULL = sem filtro. dtini/dtfim sao a data de emissao
--    da NFC-e (msdoceletronico.dtemissao, DATE); dtfim e' inclusive.
--    Use os MESMOS filtros no passo 3.
--
--    situacao:
--      ATUALIZA ............ o passo 3 vai gravar o valor do XML
--      OK .................. ja esta igual ao XML (ou e' 0 e o XML tambem)
--      DIVERGE ............. preenchido e diferente do XML: NAO e' alterado
--      ERRO: ... ........... casamento falhou; a venda inteira sera pulada
--
--    So o resumo: troque o SELECT final por
--      SELECT situacao, COUNT(*) FROM (<o SELECT final>) GROUP BY situacao;
--
--    Se der ORA-31011 / LPX-...: algum XML do periodo esta corrompido.
--    Estreite o periodo para achar; o passo 3 pula essa venda sozinho.
-- ---------------------------------------------------------------------------
WITH par AS (
  SELECT CAST(NULL AS DATE)        dtini,      -- ex.: DATE '2026-08-01'
         CAST(NULL AS DATE)        dtfim,      -- ex.: DATE '2026-09-30'
         CAST(NULL AS VARCHAR2(5)) codfilial   -- ex.: '1'
    FROM dual
),
doc AS (
  SELECT d.chavenfe, d.dtemissao, d.xml_nfe,
         ROW_NUMBER() OVER (PARTITION BY d.chavenfe ORDER BY d.numtrans) rn
    FROM msdoceletronico d
   WHERE d.tipo = 'P'
     AND d.xml_nfe IS NOT NULL
),
venda AS (
  SELECT v.numtrans, v.numcupom, doc.xml_nfe
    FROM msapolo_venda v
    JOIN doc ON doc.chavenfe = v.chavenfe AND doc.rn = 1
   CROSS JOIN par
   WHERE (par.dtini IS NULL OR doc.dtemissao >= par.dtini)
     AND (par.dtfim IS NULL OR doc.dtemissao <  par.dtfim + 1)
     AND (par.codfilial IS NULL
          OR LTRIM(TRIM(v.codfilial), '0') = LTRIM(TRIM(par.codfilial), '0'))
),
xml_det AS (
  SELECT ve.numtrans, x.nitem, TRIM(x.cprod) cprod,
         NVL(TO_NUMBER(TRIM(x.vbc),   '9999999999999D9999',
                       'NLS_NUMERIC_CHARACTERS=''.,'''), 0) vbc,
         NVL(TO_NUMBER(TRIM(x.vicms), '9999999999999D9999',
                       'NLS_NUMERIC_CHARACTERS=''.,'''), 0) vicms
    FROM venda ve,
         XMLTABLE(XMLNAMESPACES(DEFAULT 'http://www.portalfiscal.inf.br/nfe'),
                  '//det'
                  -- SUBSTR a partir do primeiro '<' descarta BOM/lixo antes
                  -- do XML, que o XMLTYPE recusa
                  PASSING XMLTYPE(SUBSTR(ve.xml_nfe, INSTR(ve.xml_nfe, '<')))
                  COLUMNS nitem NUMBER       PATH '@nItem',
                          cprod VARCHAR2(60) PATH 'prod/cProd',
                          vbc   VARCHAR2(30) PATH 'imposto/ICMS/*/vBC',
                          vicms VARCHAR2(30) PATH 'imposto/ICMS/*/vICMS') x
),
item_ativo AS (
  SELECT i.numtrans, i.numseqitem, i.codprod, i.vbc_nfe, i.vicms_nfe,
         ROW_NUMBER() OVER (PARTITION BY i.numtrans ORDER BY i.numseqitem) pos
    FROM msapolo_venda_item i
   WHERE i.dtcancel IS NULL
     AND i.numtrans IN (SELECT numtrans FROM venda)
)
SELECT NVL(a.numtrans, x.numtrans) numtrans,
       a.numseqitem,
       NVL(a.pos, x.nitem)         nitem,
       a.codprod,
       x.cprod,
       a.vbc_nfe                   vbc_atual,
       x.vbc                       vbc_xml,
       a.vicms_nfe                 vicms_atual,
       x.vicms                     vicms_xml,
       CASE
         WHEN a.numtrans IS NULL              THEN 'ERRO: DET A MAIS NO XML'
         WHEN x.numtrans IS NULL              THEN 'ERRO: ITEM SEM DET NO XML'
         WHEN x.cprod <> TO_CHAR(a.codprod)   THEN 'ERRO: PRODUTO DIFERENTE'
         WHEN a.vbc_nfe IS NULL OR a.vicms_nfe IS NULL
           OR (a.vbc_nfe   = 0 AND x.vbc   <> 0)
           OR (a.vicms_nfe = 0 AND x.vicms <> 0) THEN 'ATUALIZA'
         WHEN a.vbc_nfe <> x.vbc OR a.vicms_nfe <> x.vicms THEN 'DIVERGE'
         ELSE 'OK'
       END situacao
  FROM item_ativo a
  FULL OUTER JOIN xml_det x
    ON x.numtrans = a.numtrans
   AND x.nitem    = a.pos
 ORDER BY 1, 3;


-- ---------------------------------------------------------------------------
-- 2b) ANTES: conferencia da MSMOV
--     So rode se o passo 1 mostrou VBC_NFE/VICMS_NFE na MSMOV e NUMTRANS_ERP
--     na MSAPOLO_VENDA. Mesmos filtros do passo 2.
-- ---------------------------------------------------------------------------
WITH par AS (
  SELECT CAST(NULL AS DATE)        dtini,
         CAST(NULL AS DATE)        dtfim,
         CAST(NULL AS VARCHAR2(5)) codfilial
    FROM dual
),
doc AS (
  SELECT d.chavenfe, d.dtemissao, d.xml_nfe,
         ROW_NUMBER() OVER (PARTITION BY d.chavenfe ORDER BY d.numtrans) rn
    FROM msdoceletronico d
   WHERE d.tipo = 'P'
     AND d.xml_nfe IS NOT NULL
),
venda AS (
  SELECT v.numtrans, v.numtrans_erp, doc.xml_nfe
    FROM msapolo_venda v
    JOIN doc ON doc.chavenfe = v.chavenfe AND doc.rn = 1
   CROSS JOIN par
   WHERE v.numtrans_erp IS NOT NULL
     AND (par.dtini IS NULL OR doc.dtemissao >= par.dtini)
     AND (par.dtfim IS NULL OR doc.dtemissao <  par.dtfim + 1)
     AND (par.codfilial IS NULL
          OR LTRIM(TRIM(v.codfilial), '0') = LTRIM(TRIM(par.codfilial), '0'))
),
xml_det AS (
  SELECT ve.numtrans, ve.numtrans_erp, x.nitem, TRIM(x.cprod) cprod,
         NVL(TO_NUMBER(TRIM(x.vbc),   '9999999999999D9999',
                       'NLS_NUMERIC_CHARACTERS=''.,'''), 0) vbc,
         NVL(TO_NUMBER(TRIM(x.vicms), '9999999999999D9999',
                       'NLS_NUMERIC_CHARACTERS=''.,'''), 0) vicms
    FROM venda ve,
         XMLTABLE(XMLNAMESPACES(DEFAULT 'http://www.portalfiscal.inf.br/nfe'),
                  '//det'
                  PASSING XMLTYPE(SUBSTR(ve.xml_nfe, INSTR(ve.xml_nfe, '<')))
                  COLUMNS nitem NUMBER       PATH '@nItem',
                          cprod VARCHAR2(60) PATH 'prod/cProd',
                          vbc   VARCHAR2(30) PATH 'imposto/ICMS/*/vBC',
                          vicms VARCHAR2(30) PATH 'imposto/ICMS/*/vICMS') x
),
mov AS (
  SELECT m.numtrans, m.item, m.codprod, m.vbc_nfe, m.vicms_nfe
    FROM msmov m
   WHERE m.numtrans IN (SELECT numtrans_erp FROM venda)
)
SELECT NVL(m.numtrans, x.numtrans_erp) numtrans_erp,
       x.numtrans                      numtrans_pdv,
       NVL(m.item, x.nitem)            item,
       m.codprod,
       x.cprod,
       m.vbc_nfe                       vbc_atual,
       x.vbc                           vbc_xml,
       m.vicms_nfe                     vicms_atual,
       x.vicms                         vicms_xml,
       CASE
         WHEN m.numtrans IS NULL              THEN 'ERRO: DET SEM ITEM NA MSMOV'
         WHEN x.numtrans_erp IS NULL          THEN 'ERRO: MSMOV SEM DET NO XML'
         WHEN x.cprod <> TO_CHAR(m.codprod)   THEN 'ERRO: PRODUTO DIFERENTE'
         WHEN m.vbc_nfe IS NULL OR m.vicms_nfe IS NULL
           OR (m.vbc_nfe   = 0 AND x.vbc   <> 0)
           OR (m.vicms_nfe = 0 AND x.vicms <> 0) THEN 'ATUALIZA'
         WHEN m.vbc_nfe <> x.vbc OR m.vicms_nfe <> x.vicms THEN 'DIVERGE'
         ELSE 'OK'
       END situacao
  FROM mov m
  FULL OUTER JOIN xml_det x
    ON x.numtrans_erp = m.numtrans
   AND x.nitem        = m.item
 ORDER BY 1, 3;


-- ---------------------------------------------------------------------------
-- 3) UPDATE
--    Uma venda por vez, com SAVEPOINT: XML corrompido ou item que nao casa
--    pula SO aquela venda (listada no DBMS_OUTPUT) e o resto segue.
--    MSMOV e as colunas novas vao por SQL dinamico para o bloco compilar
--    mesmo onde elas ainda nao existem (o bloco avisa e segue sem a MSMOV).
--    Em SQL*Plus / SQL Developer, ligue a saida antes:
-- set serveroutput on size unlimited
-- ---------------------------------------------------------------------------
DECLARE
  -- Filtros (NULL = sem filtro). Os MESMOS do passo 2.
  c_dtini     CONSTANT DATE        := NULL;   -- ex.: DATE '2026-08-01'
  c_dtfim     CONSTANT DATE        := NULL;   -- ex.: DATE '2026-09-30'
  c_codfilial CONSTANT VARCHAR2(5) := NULL;   -- ex.: '1'

  -- Itens ativos: so preenche NULL/0, e so conta quando muda alguma coisa
  c_upd_item CONSTANT VARCHAR2(1000) := q'[
    UPDATE msapolo_venda_item
       SET vbc_nfe   = CASE WHEN NVL(vbc_nfe, 0)   = 0 THEN :vbc   ELSE vbc_nfe   END,
           vicms_nfe = CASE WHEN NVL(vicms_nfe, 0) = 0 THEN :vicms ELSE vicms_nfe END
     WHERE numtrans   = :numtrans
       AND numseqitem = :numseqitem
       AND (   vbc_nfe IS NULL OR vicms_nfe IS NULL
            OR (vbc_nfe = 0 AND :vbc2 <> 0) OR (vicms_nfe = 0 AND :vicms2 <> 0))]';

  -- Itens cancelados no cupom: nao estao no XML, ficam com 0
  c_upd_cancel CONSTANT VARCHAR2(1000) := q'[
    UPDATE msapolo_venda_item
       SET vbc_nfe   = NVL(vbc_nfe, 0),
           vicms_nfe = NVL(vicms_nfe, 0)
     WHERE numtrans = :numtrans
       AND dtcancel IS NOT NULL
       AND (vbc_nfe IS NULL OR vicms_nfe IS NULL)]';

  c_upd_mov CONSTANT VARCHAR2(1000) := q'[
    UPDATE msmov
       SET vbc_nfe   = CASE WHEN NVL(vbc_nfe, 0)   = 0 THEN :vbc   ELSE vbc_nfe   END,
           vicms_nfe = CASE WHEN NVL(vicms_nfe, 0) = 0 THEN :vicms ELSE vicms_nfe END
     WHERE numtrans = :numtrans
       AND item     = :item
       AND codprod  = :codprod
       AND (   vbc_nfe IS NULL OR vicms_nfe IS NULL
            OR (vbc_nfe = 0 AND :vbc2 <> 0) OR (vicms_nfe = 0 AND :vicms2 <> 0))]';

  TYPE t_det IS RECORD (
    nitem  NUMBER,
    cprod  VARCHAR2(60),
    vbc    NUMBER,
    vicms  NUMBER
  );
  TYPE t_tab_det IS TABLE OF t_det  INDEX BY PLS_INTEGER;
  TYPE t_tab_num IS TABLE OF NUMBER INDEX BY PLS_INTEGER;

  l_det     t_tab_det;   -- det do XML, em ordem de nItem
  l_seq     t_tab_num;   -- numseqitem do item ativo na posicao k
  l_cod     t_tab_num;   -- codprod do item ativo na posicao k
  l_pos     PLS_INTEGER;
  l_motivo  VARCHAR2(400);
  l_erp     NUMBER;
  l_qt      NUMBER;
  l_tem_mov BOOLEAN;
  l_tem_erp BOOLEAN;

  n_vendas      PLS_INTEGER := 0;
  n_puladas     PLS_INTEGER := 0;
  n_erros       PLS_INTEGER := 0;
  n_item        PLS_INTEGER := 0;
  n_cancel      PLS_INTEGER := 0;
  n_mov         PLS_INTEGER := 0;
  n_mov_pulada  PLS_INTEGER := 0;

  FUNCTION tem_coluna(p_tabela VARCHAR2, p_coluna VARCHAR2) RETURN BOOLEAN IS
    l_n NUMBER;
  BEGIN
    SELECT COUNT(*) INTO l_n
      FROM user_tab_columns
     WHERE table_name  = UPPER(p_tabela)
       AND column_name = UPPER(p_coluna);
    RETURN l_n > 0;
  END;

  PROCEDURE msg(p_texto VARCHAR2) IS
  BEGIN
    DBMS_OUTPUT.PUT_LINE(p_texto);
  END;
BEGIN
  DBMS_OUTPUT.ENABLE(NULL);

  IF NOT (tem_coluna('MSAPOLO_VENDA_ITEM', 'VBC_NFE')
          AND tem_coluna('MSAPOLO_VENDA_ITEM', 'VICMS_NFE')) THEN
    RAISE_APPLICATION_ERROR(-20001,
      'MSAPOLO_VENDA_ITEM sem VBC_NFE/VICMS_NFE: rode o ALTER do passo 1');
  END IF;

  l_tem_mov := tem_coluna('MSMOV', 'VBC_NFE') AND tem_coluna('MSMOV', 'VICMS_NFE');
  l_tem_erp := tem_coluna('MSAPOLO_VENDA', 'NUMTRANS_ERP');
  IF NOT l_tem_mov THEN
    msg('AVISO: MSMOV sem VBC_NFE/VICMS_NFE - so a MSAPOLO_VENDA_ITEM sera atualizada');
  END IF;
  IF NOT l_tem_erp THEN
    msg('AVISO: MSAPOLO_VENDA sem NUMTRANS_ERP - sem ligacao com a MSMOV, ' ||
        'so a MSAPOLO_VENDA_ITEM sera atualizada');
  END IF;

  FOR v IN (SELECT pv.numtrans, pv.numcupom, d.xml_nfe
              FROM msapolo_venda pv
              JOIN (SELECT d.chavenfe, d.dtemissao, d.xml_nfe,
                           ROW_NUMBER() OVER (PARTITION BY d.chavenfe
                                                  ORDER BY d.numtrans) rn
                      FROM msdoceletronico d
                     WHERE d.tipo = 'P'
                       AND d.xml_nfe IS NOT NULL) d
                ON d.chavenfe = pv.chavenfe
               AND d.rn = 1
             WHERE (c_dtini IS NULL OR d.dtemissao >= c_dtini)
               AND (c_dtfim IS NULL OR d.dtemissao <  c_dtfim + 1)
               AND (c_codfilial IS NULL
                    OR LTRIM(TRIM(pv.codfilial), '0') = LTRIM(TRIM(c_codfilial), '0'))
             ORDER BY pv.numtrans) LOOP

    n_vendas := n_vendas + 1;
    SAVEPOINT sp_venda;
    BEGIN
      l_det.DELETE;
      l_seq.DELETE;
      l_cod.DELETE;
      l_motivo := NULL;

      -- 3.1 det do XML (nItem, cProd, vBC, vICMS)
      SELECT x.nitem,
             TRIM(x.cprod),
             NVL(TO_NUMBER(TRIM(x.vbc),   '9999999999999D9999',
                           'NLS_NUMERIC_CHARACTERS=''.,'''), 0),
             NVL(TO_NUMBER(TRIM(x.vicms), '9999999999999D9999',
                           'NLS_NUMERIC_CHARACTERS=''.,'''), 0)
        BULK COLLECT INTO l_det
        FROM XMLTABLE(XMLNAMESPACES(DEFAULT 'http://www.portalfiscal.inf.br/nfe'),
                      '//det'
                      PASSING XMLTYPE(SUBSTR(v.xml_nfe, INSTR(v.xml_nfe, '<')))
                      COLUMNS nitem NUMBER       PATH '@nItem',
                              cprod VARCHAR2(60) PATH 'prod/cProd',
                              vbc   VARCHAR2(30) PATH 'imposto/ICMS/*/vBC',
                              vicms VARCHAR2(30) PATH 'imposto/ICMS/*/vICMS') x
       ORDER BY x.nitem;

      IF l_det.COUNT = 0 THEN
        l_motivo := 'XML sem det';
      END IF;

      -- 3.2 casa a posicao k do item ativo com o det de nItem = k
      l_pos := 0;
      IF l_motivo IS NULL THEN
        FOR i IN (SELECT numseqitem, codprod
                    FROM msapolo_venda_item
                   WHERE numtrans = v.numtrans
                     AND dtcancel IS NULL
                   ORDER BY numseqitem) LOOP
          l_pos := l_pos + 1;
          IF l_pos > l_det.COUNT THEN
            l_motivo := 'venda com mais itens ativos que o XML (' ||
                        l_det.COUNT || ' det)';
            EXIT;
          ELSIF l_det(l_pos).nitem <> l_pos
             OR NVL(l_det(l_pos).cprod, '?') <> TO_CHAR(i.codprod) THEN
            l_motivo := 'nItem ' || l_det(l_pos).nitem || ' cProd ' ||
                        l_det(l_pos).cprod || ' x numseqitem ' || i.numseqitem ||
                        ' codprod ' || i.codprod;
            EXIT;
          END IF;
          l_seq(l_pos) := i.numseqitem;
          l_cod(l_pos) := i.codprod;
        END LOOP;

        IF l_motivo IS NULL AND l_pos <> l_det.COUNT THEN
          l_motivo := 'XML com ' || l_det.COUNT || ' det, venda com ' ||
                      l_pos || ' itens ativos';
        END IF;
      END IF;

      IF l_motivo IS NOT NULL THEN
        n_puladas := n_puladas + 1;
        msg('PULADA numtrans ' || v.numtrans || ' cupom ' || v.numcupom ||
            ': ' || l_motivo);
      ELSE
        -- 3.3 MSAPOLO_VENDA_ITEM
        FOR k IN 1 .. l_det.COUNT LOOP
          EXECUTE IMMEDIATE c_upd_item
            USING l_det(k).vbc, l_det(k).vicms, v.numtrans, l_seq(k),
                  l_det(k).vbc, l_det(k).vicms;
          n_item := n_item + SQL%ROWCOUNT;
        END LOOP;

        EXECUTE IMMEDIATE c_upd_cancel USING v.numtrans;
        n_cancel := n_cancel + SQL%ROWCOUNT;

        -- 3.4 MSMOV da NF gerada a partir desta venda
        IF l_tem_mov AND l_tem_erp THEN
          EXECUTE IMMEDIATE
            'SELECT MAX(numtrans_erp) FROM msapolo_venda WHERE numtrans = :n'
            INTO l_erp USING v.numtrans;

          IF l_erp IS NOT NULL THEN
            -- Mesma quantidade de itens e mesmo produto em cada posicao,
            -- senao a MSMOV nao veio da MSAPOLO_GERAR_NF (ou foi mexida)
            EXECUTE IMMEDIATE 'SELECT COUNT(*) FROM msmov WHERE numtrans = :e'
              INTO l_qt USING l_erp;
            IF l_qt <> l_det.COUNT THEN
              l_motivo := 'MSMOV ' || l_erp || ' com ' || l_qt ||
                          ' itens, XML com ' || l_det.COUNT || ' det';
            ELSE
              FOR k IN 1 .. l_det.COUNT LOOP
                EXECUTE IMMEDIATE
                  'SELECT COUNT(*) FROM msmov ' ||
                  ' WHERE numtrans = :e AND item = :k AND codprod = :c'
                  INTO l_qt USING l_erp, k, l_cod(k);
                IF l_qt <> 1 THEN
                  l_motivo := 'MSMOV ' || l_erp || ' item ' || k ||
                              ' nao e'' o codprod ' || l_cod(k);
                  EXIT;
                END IF;
              END LOOP;
            END IF;

            IF l_motivo IS NOT NULL THEN
              n_mov_pulada := n_mov_pulada + 1;
              msg('MSMOV PULADA numtrans ' || v.numtrans || ' cupom ' ||
                  v.numcupom || ': ' || l_motivo);
            ELSE
              FOR k IN 1 .. l_det.COUNT LOOP
                EXECUTE IMMEDIATE c_upd_mov
                  USING l_det(k).vbc, l_det(k).vicms, l_erp, k, l_cod(k),
                        l_det(k).vbc, l_det(k).vicms;
                n_mov := n_mov + SQL%ROWCOUNT;
              END LOOP;
            END IF;
          END IF;
        END IF;
      END IF;

    EXCEPTION
      WHEN OTHERS THEN
        ROLLBACK TO sp_venda;
        n_erros := n_erros + 1;
        msg('ERRO numtrans ' || v.numtrans || ' cupom ' || v.numcupom ||
            ': ' || SQLERRM);
    END;
  END LOOP;

  msg('-----------------------------------------------------------');
  msg('Vendas lidas ..................... ' || n_vendas);
  msg('Vendas puladas (item nao casa) ... ' || n_puladas);
  msg('Vendas com erro (XML etc.) ....... ' || n_erros);
  msg('MSAPOLO_VENDA_ITEM atualizados ... ' || n_item);
  msg('  itens cancelados zerados ....... ' || n_cancel);
  msg('MSMOV atualizados ................ ' || n_mov);
  msg('MSMOV puladas (nao casa) ......... ' || n_mov_pulada);
  msg('Nada commitado ainda: confira o passo 4 e rode o COMMIT do passo 5.');
END;
/


-- ---------------------------------------------------------------------------
-- 4) DEPOIS: rode de novo os SELECTs dos passos 2 e 2b, com os mesmos
--    filtros. Nao deve sobrar 'ATUALIZA'. O que sobrar de 'ERRO: ...' e
--    'DIVERGE' foi deixado como estava de proposito (ver cabecalho).
--
--    Totais por venda, para bater com o vBC/vICMS do total da nota
--    (ICMSTot) - o rateio do PDV fecha a soma exata:
--
--      SELECT i.numtrans, SUM(i.vbc_nfe) vbc, SUM(i.vicms_nfe) vicms
--        FROM msapolo_venda_item i
--       GROUP BY i.numtrans
--       ORDER BY i.numtrans;
-- ---------------------------------------------------------------------------


-- ---------------------------------------------------------------------------
-- 5) COMMIT
--    Se a conferencia do passo 4 nao bateu, rode ROLLBACK em vez deste COMMIT.
-- ---------------------------------------------------------------------------
COMMIT;
