-- ============================================================================
-- ApoloWeb -> ERP Colosso
-- Gera MSNF / MSMOV / MSLANC / MSPARCELAS / MSNFCOB a partir de uma venda
-- do PDV (msapolo_venda + _item + _pagto) e vincula o XML em MSDOCELETRONICO.
--
-- Baseada na rotina 3185 (uPedido.pas: SQL_Pedido_Simplificado e
-- SQL_Gerar_Contas_Receber). Diferencas de proposito:
--   * a 3185 recebe um XML de pedido; aqui a origem e' a propria msapolo_venda
--   * a venda do PDV ja nasce faturada e com NFC-e autorizada, entao nao ha
--     posicao de pedido (nasce 'F') nem numeracao a atribuir depois
--   * serie e numnota saem da chave da NFC-e, nao do msseriedoc: a nota fiscal
--     ja existe e foi autorizada pela SEFAZ com aquela numeracao
--
-- Decisoes tomadas com o cliente em 2026-08-21:
--   codoper .... 'S' (Venda de Mercadoria; financ='R', status='A', coddoc=2)
--   financeiro . MSLANC/MSPARCELAS SEMPRE, e EM ABERTO (sem baixa automatica)
--   codcob ..... D dinheiro, CH cheque, CCRED/CDEBT cartao TEF, POSC/POSD
--                cartao POS, PIX; demais vem do msapolo_meiopagto. A traducao
--                e' feita no upload (uSincronizacao.CodCobERP), entao aqui o
--                codcob de msapolo_venda_pagto ja e' o do ERP - ver secao 2
--   codcli ..... msfilial.codconsumidor da filial da venda, quando o cupom
--                vem com codcli 0 (consumidor nao identificado)
--
-- NAO movimenta estoque. A 3185 tambem nao baixa MSEST no faturamento (so
-- mexe em qtreserv quando o pedido esta em L/M); a baixa fica para o processo
-- do ERP que consome msmov.processado / estoq_atualizado. Se a baixa tiver de
-- sair daqui, e' uma decisao a parte - dobrar a baixa e' pior que nao dar.
-- ============================================================================


-- ---------------------------------------------------------------------------
-- 1. Coluna de controle na msapolo_venda (idempotencia)
--    Guarda o numtrans gerado no ERP. Venda ja processada nao entra de novo.
-- ---------------------------------------------------------------------------
ALTER TABLE msapolo_venda ADD (numtrans_erp NUMBER(15));

CREATE INDEX msapolo_venda_idx03 ON msapolo_venda (numtrans_erp);


-- ---------------------------------------------------------------------------
-- 2. Cobrancas do PDV no MSCOB
--
--    O PDV usa codigos proprios na tela e o upload os traduz para o codcob do
--    ERP (uSincronizacao.CodCobERP):
--
--      01 Dinheiro ................. D
--      02 Cheque ................... CH
--      03 Cartao TEF credito ....... CCRED     (codtipotransacao = 1)
--      03 Cartao TEF debito ........ CDEBT     (codtipotransacao = 2)
--      17 PIX (TEF) ................ PIX
--      99 POS credito .............. POSC      (codtipotransacao = 1)
--      99 POS debito ............... POSD      (codtipotransacao = 2)
--      demais ...................... o codcob do msapolo_meiopagto
--                                    (aba Cobrancas Adicionais), sem traducao
--
--    Nada a cadastrar: em 21/08/2026 o MSCOB ja tinha D, CH, CCRED, CDEBT,
--    POSC, POSD, PIX, PIXM e BK. So conferir que continuam la:
--
--      SELECT codcob, cobranca FROM mscob
--       WHERE codcob IN ('D','CH','CCRED','CDEBT','POSC','POSD','PIX');
--
--    Se algum sumir, a procedure nao perde o titulo: cai no codcob da NF e
--    registra. Mas o relatorio financeiro sai com a cobranca errada.
-- ---------------------------------------------------------------------------


-- ---------------------------------------------------------------------------
-- 2a. Acerto dos pagamentos ja gravados
--     As vendas que subiram antes da traducao estao com o codigo do PDV.
--     Rodar ANTES de processar: e' esse codcob que vai para MSPARCELAS.
-- ---------------------------------------------------------------------------
UPDATE msapolo_venda_pagto p
   SET p.codcob =
       CASE
         WHEN TRIM(p.codcob) = '01' THEN 'D'
         WHEN TRIM(p.codcob) = '02' THEN 'CH'
         WHEN TRIM(p.codcob) = '17' THEN 'PIX'
         WHEN TRIM(p.codcob) = '03' THEN
           CASE WHEN NVL(p.codtipotransacao,1) = 2 THEN 'CDEBT' ELSE 'CCRED' END
         WHEN TRIM(p.codcob) = '99' THEN
           CASE WHEN NVL(p.codtipotransacao,1) = 2 THEN 'POSD' ELSE 'POSC' END
         ELSE p.codcob
       END
 WHERE TRIM(p.codcob) IN ('01','02','03','17','99')
   AND EXISTS (SELECT 1 FROM msapolo_venda v
                WHERE v.numtrans = p.numtrans AND v.numtrans_erp IS NULL);

COMMIT;

-- Conferencia depois do UPDATE (nao deve sobrar codigo numerico do PDV):
--   SELECT codcob, COUNT(*) FROM msapolo_venda_pagto GROUP BY codcob;


-- ---------------------------------------------------------------------------
-- 2b. codfilial: nada a corrigir no historico
--     O PDV tinha '01' fixo no codigo em vez do codfilial de msapolo_caixa
--     (corrigido em uBridge.pas). As 87 vendas que ja subiram estao com '1',
--     conferido por  SELECT '['||codfilial||']', LENGTH(codfilial) ... - ou
--     seja, o valor certo. Se aparecer '01' em alguma carga futura:
--
--       UPDATE msapolo_venda v SET v.codfilial = LTRIM(v.codfilial,'0')
--        WHERE v.numtrans_erp IS NULL AND v.codfilial LIKE '0%';
-- ---------------------------------------------------------------------------


-- ---------------------------------------------------------------------------
-- 3. Consumidor nao identificado: nada a configurar
--    Sai de msfilial.codconsumidor da propria filial da venda - o mesmo
--    codigo que o PDV ja usa quando o CPF informado nao esta no cadastro.
--    Conferir que esta preenchido e aponta para um mscliente valido:
--
--      SELECT f.codfilial, f.codconsumidor, c.nome
--        FROM msfilial f LEFT JOIN mscliente c ON c.codcli = f.codconsumidor;
-- ---------------------------------------------------------------------------


-- ---------------------------------------------------------------------------
-- 4. A procedure
-- ---------------------------------------------------------------------------
CREATE OR REPLACE PROCEDURE MSAPOLO_GERAR_NF (
  p_numtrans_pdv IN  NUMBER,                  -- msapolo_venda.numtrans
  p_codrotina    IN  NUMBER   DEFAULT 8002,   -- rotina do PDV
  p_matricula    IN  NUMBER   DEFAULT NULL,   -- default: operador da venda
  p_numtrans_erp OUT NUMBER,                  -- msnf.numtrans gerado
  p_retorno      OUT VARCHAR2                 -- 'sucesso' ou o motivo da recusa
) IS
  venda    msapolo_venda%ROWTYPE;
  nf       msnf%ROWTYPE;
  mov      msmov%ROWTYPE;
  lanc     mslanc%ROWTYPE;
  parcela  msparcelas%ROWTYPE;
  tipodoc  mstipodoc%ROWTYPE;
  produto  msproduto%ROWTYPE;

  -- PL/SQL nao aceita "registro := NULL"; zerar e' atribuir um record vazio
  mov_vazio     msmov%ROWTYPE;
  parcela_vazia msparcelas%ROWTYPE;

  v_codoper     VARCHAR2(5);
  v_codcli      NUMBER;
  v_matricula   NUMBER;
  v_item        NUMBER := 0;
  v_qtd         NUMBER;
  v_totparc     NUMBER;
  v_numparcela  NUMBER := 0;
  v_soma_pagto  NUMBER;
  v_chave       VARCHAR2(60);

  e_recusa EXCEPTION;

  -- A chave da NFC-e carrega serie (pos 23-25) e numero (pos 26-34). Usar a
  -- numeracao ja autorizada evita divergir do que foi para a SEFAZ.
  FUNCTION SerieDaChave(p_chave VARCHAR2) RETURN VARCHAR2 IS
  BEGIN
    IF LENGTH(NVL(p_chave, '')) <> 44 THEN RETURN NULL; END IF;
    RETURN TO_CHAR(TO_NUMBER(SUBSTR(p_chave, 23, 3)));
  EXCEPTION WHEN OTHERS THEN RETURN NULL;
  END;

  FUNCTION NumNotaDaChave(p_chave VARCHAR2) RETURN NUMBER IS
  BEGIN
    IF LENGTH(NVL(p_chave, '')) <> 44 THEN RETURN 0; END IF;
    RETURN TO_NUMBER(SUBSTR(p_chave, 26, 9));
  EXCEPTION WHEN OTHERS THEN RETURN 0;
  END;

  -- O PDV manda data/hora como texto 'YYYY-MM-DD HH24:MI:SS', e vazio e' comum
  -- (pagamento a vista nao tem vencimento). TO_DATE direto derrubaria a venda
  -- inteira por causa de um campo em branco.
  FUNCTION DataDeTexto(p_txt VARCHAR2, p_default DATE) RETURN DATE IS
  BEGIN
    IF TRIM(NVL(p_txt, '')) IS NULL THEN RETURN p_default; END IF;
    IF LENGTH(TRIM(p_txt)) >= 19 THEN
      RETURN TO_DATE(SUBSTR(TRIM(p_txt), 1, 19), 'YYYY-MM-DD HH24:MI:SS');
    END IF;
    RETURN TO_DATE(SUBSTR(TRIM(p_txt), 1, 10), 'YYYY-MM-DD');
  EXCEPTION WHEN OTHERS THEN RETURN p_default;
  END;

BEGIN
  p_numtrans_erp := NULL;
  p_retorno      := 'sucesso';

  -- ---- 4.1 venda de origem -------------------------------------------------
  BEGIN
    SELECT * INTO venda FROM msapolo_venda WHERE numtrans = p_numtrans_pdv;
  EXCEPTION
    WHEN NO_DATA_FOUND THEN
      p_retorno := 'Venda ' || p_numtrans_pdv || ' nao encontrada em msapolo_venda';
      RAISE e_recusa;
  END;

  IF venda.numtrans_erp IS NOT NULL THEN
    -- Idempotente de proposito: o PDV pode reenviar a mesma venda
    p_numtrans_erp := venda.numtrans_erp;
    p_retorno := 'Venda ja processada (numtrans ERP ' || venda.numtrans_erp || ')';
    RETURN;
  END IF;

  IF NVL(venda.codoper, 'V') = 'C' THEN
    p_retorno := 'Venda cancelada no PDV - nada a gerar';
    RAISE e_recusa;
  END IF;

  IF NVL(venda.valorvenda, 0) = 0 THEN
    p_retorno := 'Venda com valor zerado';
    RAISE e_recusa;
  END IF;

  v_matricula := NVL(p_matricula, venda.codoperador);

  -- ---- 4.2 tipo de documento ----------------------------------------------
  v_codoper := 'S';   -- decidido com o cliente: Venda de Mercadoria
  BEGIN
    SELECT * INTO tipodoc FROM mstipodoc WHERE codoper = v_codoper;
  EXCEPTION
    WHEN NO_DATA_FOUND THEN
      p_retorno := 'mstipodoc sem o codoper ' || v_codoper;
      RAISE e_recusa;
  END;

  -- ---- 4.3 cliente ---------------------------------------------------------
  -- Venda sem cliente identificado usa o consumidor padrao da filial. E' o
  -- mesmo codigo que o PDV ja aplica quando o CPF informado nao esta no
  -- cadastro (uBridge.DoIdentificarConsumidor).
  -- LTRIM dos zeros porque msfilial.codfilial e' '1' e o PDV grava '01'.
  v_codcli := NVL(venda.codcli, 0);
  IF v_codcli = 0 THEN
    SELECT MAX(codconsumidor) INTO v_codcli
      FROM msfilial
     WHERE LTRIM(codfilial, '0') = LTRIM(venda.codfilial, '0');
  END IF;

  SELECT COUNT(*) INTO v_qtd FROM mscliente WHERE codcli = v_codcli;
  IF NVL(v_codcli, 0) = 0 OR v_qtd = 0 THEN
    p_retorno := 'Filial ' || venda.codfilial || ' sem codconsumidor valido ' ||
                 'em msfilial (ou o cliente nao existe em mscliente).';
    RAISE e_recusa;
  END IF;

  -- ---- 4.4 cabecalho (MSNF) ------------------------------------------------
  v_chave := REPLACE(TRIM(venda.chavenfe), 'NFe', '');

  nf.numtrans      := seq_prox_numtrans_mov.NEXTVAL;
  p_numtrans_erp   := nf.numtrans;
  INSERT INTO mstransacao (transacao, tipo, dthora)
    VALUES (nf.numtrans, 1, SYSDATE);

  nf.codfilial     := venda.codfilial;
  nf.codcli        := v_codcli;
  nf.codoper       := tipodoc.codoper;
  nf.tipo          := 'S';
  nf.posicao       := 'F';                      -- venda de PDV ja nasce faturada
  nf.status        := tipodoc.status;
  nf.faturamento   := NVL(tipodoc.faturamento, 'S');
  nf.bonificado    := NVL(tipodoc.bonificado, 'N');
  nf.tpimp         := tipodoc.tpimp;

  -- Numeracao. A serie e' a do caixa, em msapolo_caixa.serie_nfce; o numero
  -- vem da chave da NFC-e autorizada.
  nf.numnota := NumNotaDaChave(v_chave);

  SELECT TO_CHAR(MAX(serie_nfce)) INTO nf.serie
    FROM msapolo_caixa
   WHERE numcaixa = venda.numcaixa;

  -- Sem cadastro do caixa, cai na serie que realmente foi para a SEFAZ; sem
  -- chave (contingencia nao transmitida), no msseriedoc com numnota 0.
  IF nf.serie IS NULL THEN
    nf.serie := SerieDaChave(v_chave);
  END IF;

  IF nf.serie IS NULL THEN
    BEGIN
      SELECT serie, modelo INTO nf.serie, nf.especie
        FROM msseriedoc
       WHERE codfilial = nf.codfilial AND coddoc = tipodoc.coddoc;
    EXCEPTION WHEN NO_DATA_FOUND THEN
      p_retorno := 'Caixa ' || venda.numcaixa || ' sem serie_nfce em ' ||
                   'msapolo_caixa e msseriedoc sem serie para codfilial ' ||
                   nf.codfilial || ' coddoc ' || tipodoc.coddoc;
      RAISE e_recusa;
    END;
  ELSE
    nf.especie := '65';                         -- NFC-e
  END IF;

  -- A serie do cadastro divergindo da chave significa que a nota foi
  -- autorizada com outra serie. Nao da para "corrigir" aqui: a SEFAZ ja tem
  -- a nota na serie da chave, e o MSNF tem que refletir o que foi emitido.
  IF v_chave IS NOT NULL AND SerieDaChave(v_chave) IS NOT NULL
     AND TO_NUMBER(nf.serie) <> TO_NUMBER(SerieDaChave(v_chave)) THEN
    p_retorno := 'Serie divergente: msapolo_caixa diz ' || nf.serie ||
                 ' e a chave da NFC-e autorizada diz ' || SerieDaChave(v_chave) ||
                 ' (caixa ' || venda.numcaixa || ', cupom ' || venda.numcupom ||
                 '). Acertar msapolo_caixa.serie_nfce antes de subir.';
    RAISE e_recusa;
  END IF;

  nf.chavenfe      := v_chave;
  nf.numvolumes    := 1;
  nf.numitens      := NVL(venda.qtdeitens, 0);
  nf.vltotal       := NVL(venda.valorvenda, 0)
                      - NVL(venda.valordesc, 0)
                      + NVL(venda.valorencargo, 0);
  nf.vlfrete       := 0;
  nf.vloutrasdesp  := 0;
  nf.codvendedor   := venda.codoperador;
  BEGIN
    SELECT codgestor INTO nf.codsupervisor FROM msfunc WHERE matricula = nf.codvendedor;
  EXCEPTION WHEN OTHERS THEN nf.codsupervisor := venda.codsupervisor;
  END;

  nf.dtemissao     := TRUNC(DataDeTexto(venda.dthriniciovenda, SYSDATE));
  nf.dtsaida       := nf.dtemissao;
  nf.dthora        := DataDeTexto(venda.dthrfimvenda, SYSDATE);
  nf.dtultalter    := CURRENT_TIMESTAMP;
  nf.codfunclanc   := v_matricula;
  nf.codrotinalanc := p_codrotina;
  nf.obs           := 'PDV caixa ' || venda.numcaixa ||
                      ' cupom ' || venda.numcupom;

  -- Cobranca da NF: a do pagamento de maior valor do cupom
  BEGIN
    SELECT codcob INTO nf.codcob FROM (
      SELECT codcob FROM msapolo_venda_pagto
       WHERE numtrans = p_numtrans_pdv
       GROUP BY codcob ORDER BY SUM(valor) DESC)
     WHERE ROWNUM = 1;
  EXCEPTION WHEN NO_DATA_FOUND THEN nf.codcob := NULL;
  END;

  SELECT NVL(MAX(numped), 0) + 1 INTO nf.numped FROM msnf;

  INSERT INTO msnf VALUES nf;

  -- ---- 4.5 itens (MSMOV) ---------------------------------------------------
  FOR reg IN (SELECT * FROM msapolo_venda_item
               WHERE numtrans = p_numtrans_pdv
                 AND dtcancel IS NULL
               ORDER BY numseqitem) LOOP

    BEGIN
      SELECT * INTO produto FROM msproduto WHERE codprod = reg.codprod;
    EXCEPTION WHEN NO_DATA_FOUND THEN
      p_retorno := 'Produto ' || reg.codprod || ' (cupom ' || venda.numcupom ||
                   ') nao existe em msproduto';
      RAISE e_recusa;
    END;

    v_item := v_item + 1;
    mov := mov_vazio;

    mov.id           := seq_prox_id_mov.NEXTVAL;
    mov.numtrans     := nf.numtrans;
    mov.item         := v_item;
    mov.codprod      := reg.codprod;
    mov.codbarra     := reg.codbarra;
    mov.unidade      := NVL(reg.unidade, produto.unidade);
    mov.qt           := NVL(reg.qt, 0);
    mov.qtnf         := mov.qt;
    mov.fator_qt     := NVL(NULLIF(produto.fator_qt, 0), 1);
    mov.punit        := NVL(reg.punit, 0);
    mov.ptabela      := NVL(reg.ptabela, reg.punit);
    mov.pbaserca     := mov.ptabela;

    -- Convencao do cupom: vlprod e' BRUTO e o desconto anda separado
    mov.vlprod       := NVL(reg.vlprod, mov.punit * mov.qt);
    mov.vldesconto   := NVL(reg.vldesconto, 0);
    mov.vldescitem   := CASE WHEN mov.qt <> 0
                             THEN ROUND(mov.vldesconto / mov.qt, 4) ELSE 0 END;
    mov.vdesc        := mov.vldesconto;
    mov.vlflex       := ROUND(NVL(mov.punit, 0) - NVL(mov.pbaserca, 0), 2);
    mov.vloutros     := 0;
    mov.vlfrete      := 0;
    mov.tx_boleto    := 0;
    mov.vlcmv        := 0;

    mov.codoper      := tipodoc.codoper;
    mov.oper         := tipodoc.oper;
    mov.tipoprod     := 'M';
    mov.indtot       := 1;
    mov.bonificado   := 'N';
    mov.calc_impostos := 'N';
    mov.codrotina    := p_codrotina;
    mov.codfunclanc  := v_matricula;
    mov.codvendedor  := NVL(reg.codvendedor, venda.codoperador);
    mov.codfornec    := produto.codfornec;
    mov.dtmov        := nf.dthora;
    mov.dtcontrole   := nf.dthora;
    mov.dtcancel     := NULL;

    mov.peso_bruto   := ROUND(mov.qt * NVL(produto.pesobruto, 0), 2);

    -- Mesmo criterio da 3185: o PDV nao movimenta MSEST aqui
    mov.custo_atualizado := 'S';
    mov.estoq_atualizado := 'S';
    mov.processado       := 'S';

    BEGIN
      SELECT qtest, qtestger INTO mov.qtest_ant, mov.qtestger_ant
        FROM msest WHERE codprod = mov.codprod AND codfilial = nf.codfilial;
    EXCEPTION WHEN NO_DATA_FOUND THEN
      mov.qtest_ant := 0; mov.qtestger_ant := 0;
    END;

    INSERT INTO msmov VALUES mov;
  END LOOP;

  IF v_item = 0 THEN
    p_retorno := 'Venda sem itens validos';
    RAISE e_recusa;
  END IF;

  -- ---- 4.6 financeiro (MSLANC / MSPARCELAS / MSNFCOB) ----------------------
  -- Gerado SEMPRE, e EM ABERTO: a baixa fica para a conferencia de caixa.
  SELECT COUNT(*), NVL(SUM(valor), 0) INTO v_totparc, v_soma_pagto
    FROM msapolo_venda_pagto WHERE numtrans = p_numtrans_pdv;

  IF v_totparc > 0 THEN
    lanc.idlanc         := SEQ_PROX_ID_LANC.NEXTVAL;
    lanc.numtrans       := nf.numtrans;
    lanc.numnota        := nf.numnota;
    lanc.codfilial      := nf.codfilial;
    lanc.codcli         := nf.codcli;
    lanc.tiporp         := 'R';
    lanc.tipolanc       := 'C';
    lanc.situacao       := 'A';
    lanc.origemlanc     := 'MERC';
    lanc.historico      := 'Venda PDV cupom ' || venda.numcupom;
    lanc.valor          := nf.vltotal;
    lanc.dtemissao      := nf.dtemissao;
    lanc.dtlanc         := CURRENT_TIMESTAMP;
    lanc.dtcompetencia  := TRUNC(CURRENT_TIMESTAMP);
    lanc.codrotinalanc  := p_codrotina;
    lanc.codfunclanc    := v_matricula;
    lanc.totparcelaorig := v_totparc;
    lanc.idcodconta     := nf.idcodconta;

    INSERT INTO mslanc VALUES lanc;

    FOR pag IN (SELECT * FROM msapolo_venda_pagto
                 WHERE numtrans = p_numtrans_pdv
                 ORDER BY numparcela, codcob) LOOP

      v_numparcela := v_numparcela + 1;
      parcela := parcela_vazia;

      parcela.id          := seq_prox_id_parcelas.NEXTVAL;
      parcela.idlanc      := lanc.idlanc;
      parcela.numparcela  := v_numparcela;
      parcela.valor       := NVL(pag.valor, 0);
      parcela.vloriginal  := parcela.valor;
      parcela.duplicata   := v_numparcela || '/' || v_totparc;
      parcela.moeda       := 'R';
      parcela.vpago       := 0;         -- em aberto
      parcela.dtpagto     := NULL;
      parcela.dtbaixa     := NULL;
      parcela.codvendedor := nf.codvendedor;
      -- Sem vencimento = a vista: vence na data da emissao
      parcela.dtvenc      := TRUNC(DataDeTexto(pag.dtvenc, nf.dtemissao));

      -- codcob do PDV usado direto (01/02/03/99/PIX cadastrados em MSCOB).
      -- Se algum nao existir, cai no codcob da NF para nao perder o titulo.
      SELECT COUNT(*) INTO v_qtd FROM mscob WHERE codcob = pag.codcob;
      parcela.codcob := CASE WHEN v_qtd > 0 THEN pag.codcob ELSE nf.codcob END;

      INSERT INTO msparcelas VALUES parcela;

      INSERT INTO msnfcob (numtrans, codcob, dtvenc, valor, parcela)
        VALUES (lanc.numtrans, parcela.codcob, parcela.dtvenc,
                parcela.valor, parcela.numparcela);
    END LOOP;
  END IF;

  -- ---- 4.7 vincular o XML da NFC-e ao numtrans da NF -----------------------
  -- O PDV grava msdoceletronico com um numtrans proprio, que nao aponta para
  -- nota nenhuma. Aqui o XML passa a pertencer a NF gerada.
  IF v_chave IS NOT NULL AND LENGTH(v_chave) = 44 THEN
    UPDATE msdoceletronico
       SET numtrans = nf.numtrans
     WHERE chavenfe = v_chave
       AND numtrans <> nf.numtrans;
  END IF;

  -- ---- 4.8 marcar a venda como processada ---------------------------------
  UPDATE msapolo_venda SET numtrans_erp = nf.numtrans
   WHERE numtrans = p_numtrans_pdv;

EXCEPTION
  WHEN e_recusa THEN
    ROLLBACK;
    p_numtrans_erp := NULL;
  WHEN OTHERS THEN
    ROLLBACK;
    p_numtrans_erp := NULL;
    p_retorno := 'ERRO ' || SQLCODE || ': ' || SUBSTR(SQLERRM, 1, 500);
END MSAPOLO_GERAR_NF;
/

SHOW ERRORS PROCEDURE MSAPOLO_GERAR_NF;


-- ---------------------------------------------------------------------------
-- 5. Como chamar (uma venda)
-- ---------------------------------------------------------------------------
-- DECLARE
--   v_numtrans NUMBER; v_ret VARCHAR2(4000);
-- BEGIN
--   MSAPOLO_GERAR_NF(p_numtrans_pdv => 1, p_numtrans_erp => v_numtrans,
--                    p_retorno => v_ret);
--   dbms_output.put_line(v_ret || ' -> numtrans ' || v_numtrans);
--   COMMIT;   -- a procedure NAO commita; quem chama decide
-- END;
-- /

-- Processar o que ainda nao subiu:
-- BEGIN
--   FOR r IN (SELECT numtrans FROM msapolo_venda
--              WHERE numtrans_erp IS NULL AND codoper = 'V' ORDER BY numtrans) LOOP
--     DECLARE v_n NUMBER; v_r VARCHAR2(4000);
--     BEGIN
--       MSAPOLO_GERAR_NF(r.numtrans, 8002, NULL, v_n, v_r);
--       dbms_output.put_line(r.numtrans || ': ' || v_r);
--     END;
--   END LOOP;
--   COMMIT;
-- END;
-- /
