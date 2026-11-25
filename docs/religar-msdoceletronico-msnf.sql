/* ==========================================================================
   ApoloWeb / retaguarda - liga o XML da NFC-e do PDV (MSDOCELETRONICO,
   tipo 'P') ao NUMTRANS da nota (MSNF), pela chave de acesso

   A regra: o XML da nota fica na MSDOCELETRONICO com o MESMO NUMTRANS da
   MSNF. Na NFC-e do PDV isso so acontecia quando o XML chegava ANTES da
   nota: o ApoloWeb gravava o XML com um NUMTRANS novo da
   SEQ_PROX_NUMTRANS_MOV e o job MSAPOLO_GERAR_NF (passo 4.7) so religa no
   momento em que cria a MSNF. O XML que sobe DEPOIS da nota ficava para
   sempre no NUMTRANS do PDV, que nao e de nota nenhuma -- e quem procura o
   XML pela transacao (Exportar XML da 4152, motor de NF-e, conferencias)
   nao acha. Corrigido na origem no uSincronizacao.pas (UploadDocEletronico,
   28/10/2026); este script acerta o que ja foi gravado.

   FERNANDES (28/10/2026, levantamento so de leitura): 17.110 XML tipo 'P'
   fora do NUMTRANS da nota (gravados de 11/09 a 28/10), todos religaveis:
   uma linha por chave, uma MSNF por chave, nenhuma dessas MSNF com linha
   propria na MSDOCELETRONICO (o NUMTRANS e a PK).

   COMO RODAR -- um passo por vez, cada bloco ate a sua barra (/):
     DBeaver   selecione o bloco do passo (do DECLARE ate o END;) e Ctrl+Enter.
               A saida (DBMS_OUTPUT) aparece na aba de saida do servidor
               (Ctrl+Shift+O, ligue antes de rodar). Deixe a transacao em modo
               MANUAL (botao de commit na barra), senao o DBeaver grava sozinho.
     SQL*Plus  antes: set serveroutput on size unlimited format wrapped
               O EXIT do cliente 11.1 grava o pendente: ROLLBACK antes de sair.
   Os parametros sao constantes no topo de cada bloco (sem DEFINE nem
   variavel de substituicao, que o DBeaver nao troca).
     Passo 1  tabela de backup MSAPOLO_DOC_RELIGAR_BKP (cria uma vez, DDL)
     Passo 2  previa (c_aplicar = 'N') ou correcao (c_aplicar = 'S').
              NAO faz COMMIT: confira e de COMMIT ou ROLLBACK voce mesmo.
              A previa nao precisa do Passo 1
     Passo 3  conferir: rode o Passo 2 de novo com c_aplicar = 'N' (nao pode
              sobrar XML "a religar")
     Passo 4  desfazer uma execucao pelo c_id_exec

   O QUE O SCRIPT CONFERE (o que falhar sai como CONFERIR e nao e tocado):
     - XML tipo 'P', chave de 44 digitos, NUMTRANS que nao e de MSNF;
     - UMA so MSNF com essa chave (com ou sem o prefixo NFe);
     - essa MSNF ainda sem linha na MSDOCELETRONICO.
   O QUE GRAVA: MSDOCELETRONICO.NUMTRANS = MSNF.NUMTRANS (antes/depois no
   backup; trava otimista: so muda se o NUMTRANS ainda e o lido).
   O que NAO muda: o XML, a MSNF, a MSLOG_CUPOM (o log do cupom continua no
   NUMTRANS do PDV, como ja acontecia quando o passo 4.7 religava), o
   evento de cancelamento (tipo 'C': a nota so tem uma linha, que e a do
   XML dela; o evento continua ligado pela chave).

   Sem procedure/package: tudo em SQL e blocos anonimos.
   ========================================================================== */

/* ---------------------------------------------------------------- Passo 1 */
-- Cria a tabela de backup se ainda nao existir (DDL: faz commit implicito,
-- por isso roda antes de qualquer alteracao).
declare
  n number;
begin
  select count(*) into n from user_tables where table_name = 'MSAPOLO_DOC_RELIGAR_BKP';
  if n = 0 then
    execute immediate '
      create table msapolo_doc_religar_bkp (
        id_exec      number not null,
        dtexec       date not null,
        usuario      varchar2(30),
        rid          varchar2(30),
        chavenfe     varchar2(60),
        ant_numtrans number,
        nov_numtrans number,
        dtdesfeito   date)';
    execute immediate 'create index msapolo_doc_religar_bkp_i1 on msapolo_doc_religar_bkp (id_exec)';
  end if;
end;
/

/* ---------------------------------------------------------------- Passo 2 */
declare
  -- ====================== PARAMETROS DO PASSO 2 ======================
  -- filial da nota (NVL(MSNF.CODFILIALNF, CODFILIAL)); vazio = todas
  c_filial  constant varchar2(4) := '';
  -- quantas linhas da previa mostrar (o resumo por mes sai sempre)
  c_mostrar constant pls_integer := 30;
  -- S: altera (sem commit); N: so mostra a previa
  c_aplicar constant varchar2(1) := 'N';
  -- ===================================================================
  type t_mes is table of pls_integer index by varchar2(7);
  m_ok      t_mes;
  m_conf    t_mes;
  v_mes     varchar2(7);
  v_id      number := 0;
  v_qnf     pls_integer;
  v_nt      number;
  v_fil     varchar2(4);
  v_ocup    pls_integer;
  v_motivo  varchar2(200);
  q_ok      pls_integer := 0;
  q_conf    pls_integer := 0;
  q_fora    pls_integer := 0;
  q_linhas  pls_integer := 0;
begin
  savepoint sp_religar;
  if upper(c_aplicar) = 'S' then
    -- dinamico: a previa roda sem a tabela de backup criada
    execute immediate 'select nvl(max(id_exec), 0) + 1 from msapolo_doc_religar_bkp' into v_id;
  end if;

  for d in (select d.rowid drid, d.numtrans, d.chavenfe, to_char(d.data, 'yyyy-mm') mes
              from msdoceletronico d
             where d.tipo = 'P'
               and length(d.chavenfe) = 44
               and not exists (select 1 from msnf x where x.numtrans = d.numtrans)
               and exists (select 1 from msnf n where n.chavenfe in (d.chavenfe, 'NFe' || d.chavenfe))
             order by d.data, d.chavenfe) loop
    v_motivo := null;
    select count(*), max(n.numtrans), max(nvl(n.codfilialnf, n.codfilial))
      into v_qnf, v_nt, v_fil
      from msnf n
     where n.chavenfe in (d.chavenfe, 'NFe' || d.chavenfe);

    if c_filial is not null and nvl(v_fil, '-') <> c_filial then
      q_fora := q_fora + 1;
      continue;
    end if;

    if v_qnf <> 1 then
      v_motivo := v_qnf || ' MSNF com esta chave';
    else
      select count(*) into v_ocup from msdoceletronico y where y.numtrans = v_nt;
      if v_ocup > 0 then
        v_motivo := 'a MSNF ' || v_nt || ' ja tem linha na MSDOCELETRONICO';
      end if;
    end if;

    v_mes := nvl(d.mes, '-');
    if v_motivo is not null then
      q_conf := q_conf + 1;
      m_conf(v_mes) := case when m_conf.exists(v_mes) then m_conf(v_mes) else 0 end + 1;
      dbms_output.put_line('CONFERIR  chave ' || d.chavenfe || ' (XML no NUMTRANS ' ||
        d.numtrans || '): ' || v_motivo);
      continue;
    end if;

    q_ok := q_ok + 1;
    m_ok(v_mes) := case when m_ok.exists(v_mes) then m_ok(v_mes) else 0 end + 1;
    if q_linhas < c_mostrar then
      q_linhas := q_linhas + 1;
      dbms_output.put_line('RELIGAR   chave ' || d.chavenfe || '  NUMTRANS ' ||
        d.numtrans || ' -> ' || v_nt || '  (filial ' || v_fil || ', XML de ' || v_mes || ')');
    end if;

    if upper(c_aplicar) = 'S' then
      execute immediate 'insert into msapolo_doc_religar_bkp (id_exec, dtexec, usuario, rid,' ||
        ' chavenfe, ant_numtrans, nov_numtrans) values (:1, sysdate, user, :2, :3, :4, :5)'
        using v_id, rowidtochar(d.drid), d.chavenfe, d.numtrans, v_nt;
      update msdoceletronico x set x.numtrans = v_nt
       where x.rowid = d.drid and x.numtrans = d.numtrans and x.chavenfe = d.chavenfe;
      if sql%rowcount <> 1 then
        rollback to sp_religar;
        raise_application_error(-20001, 'Trava otimista: o XML da chave ' || d.chavenfe ||
          ' mudou durante a correcao. Nada foi alterado; rode de novo.');
      end if;
    end if;
  end loop;

  dbms_output.put_line('');
  dbms_output.put_line('Resumo por mes de gravacao do XML (religar / conferir):');
  v_mes := m_ok.first;
  while v_mes is not null loop
    dbms_output.put_line('  ' || v_mes || '   ' || lpad(m_ok(v_mes), 7) || ' / ' ||
      case when m_conf.exists(v_mes) then m_conf(v_mes) else 0 end);
    v_mes := m_ok.next(v_mes);
  end loop;
  v_mes := m_conf.first;
  while v_mes is not null loop
    if not m_ok.exists(v_mes) then
      dbms_output.put_line('  ' || v_mes || '   ' || lpad(0, 7) || ' / ' || m_conf(v_mes));
    end if;
    v_mes := m_conf.next(v_mes);
  end loop;
  dbms_output.put_line('A religar: ' || q_ok || ' | conferir a mao: ' || q_conf ||
    case when c_filial is not null then ' | de outras filiais (ignorados): ' || q_fora end);
  if upper(c_aplicar) = 'S' then
    dbms_output.put_line('RELIGADO como ID_EXEC ' || v_id ||
      ' (backup em MSAPOLO_DOC_RELIGAR_BKP). De COMMIT para gravar ou ROLLBACK para descartar.');
  else
    dbms_output.put_line('So previa (c_aplicar = N): nada foi alterado.' ||
      case when q_linhas < q_ok then ' (mostradas ' || q_linhas || ' de ' || q_ok || ' linhas)' end);
  end if;
end;
/

/* ---------------------------------------------------------------- Passo 4 */
-- Desfazer: com c_id_exec = N (o numero que o Passo 2 mostrou), volta o
-- NUMTRANS antigo dos XML daquela execucao, so nos que ainda estao no
-- NUMTRANS novo (o que alguem mudou depois nao e tocado e aparece como
-- conflito). Tambem termina SEM commit. Com c_id_exec = 0 nao faz nada.
declare
  -- ====================== PARAMETRO DO PASSO 4 =======================
  c_id_exec constant number := 0;   -- execucao a desfazer (0 = nada)
  -- ===================================================================
  type t_cur is ref cursor;
  c       t_cur;
  v_brid  rowid;
  v_rid   varchar2(30);
  v_ch    varchar2(60);
  v_ant   number;
  v_nov   number;
  v_ok    number := 0;
  v_conf  number := 0;
begin
  if c_id_exec = 0 then
    return;
  end if;
  open c for 'select rowid, rid, chavenfe, ant_numtrans, nov_numtrans' ||
             ' from msapolo_doc_religar_bkp where id_exec = :1 and dtdesfeito is null'
    using c_id_exec;
  loop
    fetch c into v_brid, v_rid, v_ch, v_ant, v_nov;
    exit when c%notfound;
    update msdoceletronico x set x.numtrans = v_ant
     where x.rowid = chartorowid(v_rid) and x.numtrans = v_nov and x.chavenfe = v_ch;
    if sql%rowcount = 1 then
      execute immediate 'update msapolo_doc_religar_bkp set dtdesfeito = sysdate where rowid = :1'
        using v_brid;
      v_ok := v_ok + 1;
    else
      v_conf := v_conf + 1;
      dbms_output.put_line('Conflito (mudou depois da correcao): chave ' || v_ch);
    end if;
  end loop;
  close c;
  dbms_output.put_line('ID_EXEC ' || c_id_exec || ': desfeitos ' || v_ok || ' XML, ' ||
    v_conf || ' conflito(s).');
  dbms_output.put_line('De COMMIT para gravar o desfazer ou ROLLBACK para descartar.');
end;
/
