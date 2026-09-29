-- ============================================================================
-- ApoloWeb -> ERP Colosso : automacao da geracao de MSNF
--
-- A MSAPOLO_GERAR_NF (msapolo_gerar_nf.sql) processa UMA venda e nao commita.
-- Ate aqui nada a chamava: nem trigger, nem job, nem o PDV - as vendas ficavam
-- paradas em msapolo_venda com numtrans_erp NULL ate alguem rodar o loop na
-- mao. Este script poe isso para rodar sozinho.
--
-- Por que job e nao trigger: a venda sobe em tres tabelas (msapolo_venda,
-- _item e _pagto, nessa ordem, no mesmo commit do PDV). Um trigger de INSERT
-- na msapolo_venda dispararia antes dos itens existirem e geraria nota vazia.
--
-- GUARDA IMPORTANTE: so processa venda com chavenfe preenchida. A MSNF tira
-- serie e numnota da chave; sem chave sai nota com numnota 0. Venda sem NFCe
-- autorizada fica esperando de proposito, e aparece no relatorio de pendencia
-- do fim deste arquivo.
--
-- COMO RODAR: por sqlplus, que entende o "/" como fim de bloco PL/SQL:
--
--   sqlplus FERNANDES@82.39.244.20:7721/ORDOTY @msapolo_job_gerar_nf.sql
--
-- Ferramenta grafica que quebra o script no primeiro ";" corta a procedure no
-- meio e grava um objeto INVALID (PLS-00103 "end-of-file"). No DBeaver, use
-- Executar script (Alt+X), nao Executar comando (Ctrl+Enter).
-- ============================================================================


-- ---------------------------------------------------------------------------
-- 1. Log do processamento
--    Sem isso, job que falha falha em silencio.
--
--    Sem IDENTITY nem sequence de proposito: e' tabela de log, ninguem
--    referencia uma linha dela, e IDENTITY so existe do 12c em diante.
-- ---------------------------------------------------------------------------
CREATE TABLE msapolo_gerar_nf_log (
  dthora        DATE          DEFAULT SYSDATE NOT NULL,
  numtrans_pdv  NUMBER(15),
  numtrans_erp  NUMBER(15),
  retorno       VARCHAR2(4000)
);

CREATE INDEX msapolo_gerar_nf_log_idx01 ON msapolo_gerar_nf_log (dthora);
CREATE INDEX msapolo_gerar_nf_log_idx02 ON msapolo_gerar_nf_log (numtrans_pdv);


-- ---------------------------------------------------------------------------
-- 2. Varredura das pendentes
--
--    Um COMMIT por venda: uma venda com problema nao derruba as outras do
--    lote, e o que ja passou fica gravado. O numtrans_erp na msapolo_venda e'
--    a trava de idempotencia - a propria MSAPOLO_GERAR_NF recusa reprocessar.
-- ---------------------------------------------------------------------------
CREATE OR REPLACE PROCEDURE MSAPOLO_PROCESSAR_PENDENTES (
  p_processadas OUT NUMBER,
  p_recusadas   OUT NUMBER,
  p_limite      IN  NUMBER DEFAULT 200
) IS
  v_numtrans_erp NUMBER;
  v_retorno      VARCHAR2(4000);
  -- SQLCODE e SQLERRM nao podem aparecer dentro de um comando SQL: dentro do
  -- INSERT o Oracle recusa com ORA-00984 ("coluna nao permitida aqui"). Tem
  -- que passar por variavel antes.
  v_erro         VARCHAR2(4000);
BEGIN
  p_processadas := 0;
  p_recusadas   := 0;

  FOR r IN (
    -- ROWNUM em cima de uma subconsulta ordenada (e nao FETCH FIRST) para
    -- funcionar tambem em Oracle anterior ao 12c
    SELECT numtrans FROM (
      SELECT numtrans
        FROM msapolo_venda
       WHERE numtrans_erp IS NULL
         AND NVL(codoper, 'V') = 'V'
         AND NVL(TRIM(chavenfe), 'x') <> 'x'   -- guarda: sem chave nao entra
       ORDER BY numtrans
    ) WHERE ROWNUM <= p_limite
  ) LOOP
    BEGIN
      MSAPOLO_GERAR_NF(
        p_numtrans_pdv => r.numtrans,
        p_numtrans_erp => v_numtrans_erp,
        p_retorno      => v_retorno
      );

      IF v_numtrans_erp IS NOT NULL THEN
        p_processadas := p_processadas + 1;
      ELSE
        p_recusadas := p_recusadas + 1;
      END IF;

      INSERT INTO msapolo_gerar_nf_log (numtrans_pdv, numtrans_erp, retorno)
        VALUES (r.numtrans, v_numtrans_erp, v_retorno);
      COMMIT;

    EXCEPTION
      WHEN OTHERS THEN
        v_erro := 'ERRO ' || SQLCODE || ': ' || SUBSTR(SQLERRM, 1, 500);
        ROLLBACK;
        p_recusadas := p_recusadas + 1;
        INSERT INTO msapolo_gerar_nf_log (numtrans_pdv, numtrans_erp, retorno)
          VALUES (r.numtrans, NULL, v_erro);
        COMMIT;
    END;
  END LOOP;
END MSAPOLO_PROCESSAR_PENDENTES;
/

SHOW ERRORS PROCEDURE MSAPOLO_PROCESSAR_PENDENTES


-- ---------------------------------------------------------------------------
-- 3. O job (a cada 5 minutos)
-- ---------------------------------------------------------------------------
BEGIN
  DBMS_SCHEDULER.CREATE_JOB(
    job_name        => 'MSAPOLO_JOB_GERAR_NF',
    job_type        => 'PLSQL_BLOCK',
    job_action      => 'DECLARE v_p NUMBER; v_r NUMBER; '
                    || 'BEGIN MSAPOLO_PROCESSAR_PENDENTES(v_p, v_r); END;',
    start_date      => SYSTIMESTAMP,
    repeat_interval => 'FREQ=MINUTELY;INTERVAL=5',
    enabled         => TRUE,
    comments        => 'Gera MSNF/MSMOV/MSLANC das vendas do PDV ApoloWeb'
  );
END;
/


-- ---------------------------------------------------------------------------
-- 4. Acompanhamento
-- ---------------------------------------------------------------------------
-- Ultimas execucoes do job:
--   SELECT log_date, status, additional_info FROM user_scheduler_job_run_details
--    WHERE job_name = 'MSAPOLO_JOB_GERAR_NF' AND ROWNUM <= 20 ORDER BY log_date DESC;
--
-- O que o job fez com cada venda:
--   SELECT * FROM msapolo_gerar_nf_log WHERE ROWNUM <= 30 ORDER BY dthora DESC;
--
-- Venda parada e por que (as sem chave sao as que a NFCe nao foi autorizada):
--   SELECT numtrans, numcaixa, numcupom, datamovto, valorvenda,
--          CASE WHEN NVL(TRIM(chavenfe),'x') = 'x' THEN 'sem NFCe autorizada'
--               ELSE 'aguardando o job' END motivo
--     FROM msapolo_venda WHERE numtrans_erp IS NULL ORDER BY numtrans;
--
-- Parar / religar:
--   BEGIN DBMS_SCHEDULER.DISABLE('MSAPOLO_JOB_GERAR_NF'); END;
--   BEGIN DBMS_SCHEDULER.ENABLE ('MSAPOLO_JOB_GERAR_NF'); END;
--
-- Rodar agora, sem esperar os 5 min:
--   BEGIN DBMS_SCHEDULER.RUN_JOB('MSAPOLO_JOB_GERAR_NF'); END;
