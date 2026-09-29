-- =====================================================================
-- ORDOTY - tributar as NCMs que estao sem regra de IBS/CBS
-- 05/09/2026
--
-- SITUACAO ENCONTRADA
--   * produtos ativos usam 433 NCMs distintas; so ~137 tem regra cadastrada
--   * faltam 296 NCMs por filial (2.754 linhas da carga da filial 1, 25%)
--   * as filiais 2 e 3 ainda tem as 10 NCMs com regra conflitante que ja
--     foram limpas na filial 1 (a filial 2 tem 2 caixas rodando o PDV)
--   * o cadastro atual da filial 1 aponta 100% para a regra 1
--     (CST 000 / cClassTrib 000001 - tributacao integral)
--
-- O QUE ESTE SCRIPT FAZ
--   1. backup da msncm_ibs_cbs inteira
--   2. limpa as NCMs com regra conflitante em TODAS as filiais (mesmo
--      criterio ja aplicado na filial 1: fica a regra integral)
--   3. cadastra as NCMs que faltam apontando para a regra 1 (integral),
--      uma linha por NCM de produto ativo, nas filiais que tem caixa
--   4. confere e so entao voce da o COMMIT
--
-- POR QUE "INTEGRAL"
--   E' o tratamento que o cadastro ja da a todas as outras NCMs desta
--   empresa, e e' o default do varejo. NCM de alimento pode ser Anexo I
--   (aliquota reduzida) - o passo 5 lista as 43 NCMs de capitulo 01-24
--   para o contador revisar depois, com o UPDATE pronto.
--
-- IMPACTO NO CAIXA
--   Depois disto nenhum produto e' barrado por falta de regra de IBS/CBS
--   e o bloqueio da gerartabelatemporaria_apolo passa a valer de verdade
--   (o freio de 20% deixa de disparar). Produto com NCM nova continua
--   sendo barrado ate ser cadastrado - de proposito: sem regra, a NFC-e
--   dele seria rejeitada pela SEFAZ.
-- =====================================================================

-- ---------------------------------------------------------------------
-- 0) ANTES - fotografia
-- ---------------------------------------------------------------------
select codfilial, count(*) linhas, count(distinct lpad(trim(ncm),8,'0')) ncms
  from msncm_ibs_cbs group by codfilial order by 1;

select f.codfilial,
       (select count(*) from (
          select distinct lpad(trim(n.ncm),8,'0') ncm8
            from msproduto p, msncm n
           where n.idncm = p.idncm and p.dtexclusao is null) t
         where not exists (select 1 from msncm_ibs_cbs x
                            where x.codfilial = f.codfilial and x.modelo in (0,65)
                              and x.codprod is null
                              and lpad(trim(x.ncm),8,'0') = t.ncm8)) ncms_sem_regra
  from (select distinct to_number(codfilial) codfilial from msapolo_caixa) f
 order by 1;
-- Esperado antes: filial 1 -> 296, filial 2 -> 296

-- ---------------------------------------------------------------------
-- 1) BACKUP
-- ---------------------------------------------------------------------
create table msncm_ibs_cbs_bkp_20260905b as select * from msncm_ibs_cbs;

-- Desfazer tudo (depois do commit):
--   delete from msncm_ibs_cbs;
--   insert into msncm_ibs_cbs select * from msncm_ibs_cbs_bkp_20260905b;
--   commit;

-- ---------------------------------------------------------------------
-- 2) NCMs com regra conflitante - fica so a integral (filiais 2 e 3)
--    Mesmo delete que ja foi rodado na filial 1, agora sem fixar filial.
-- ---------------------------------------------------------------------
delete from msncm_ibs_cbs n
 where n.ncm is not null
   and n.id_ibs_cbs <> 1
   and exists (select 1
                 from msncm_ibs_cbs x
                where x.codfilial = n.codfilial
                  and x.ncm is not null
                  and lpad(trim(x.ncm),8,'0') = lpad(trim(n.ncm),8,'0')
                  and x.id_ibs_cbs = 1);
-- Esperado: 66 linhas (33 por filial, 2 e 3)

-- ---------------------------------------------------------------------
-- 3) Cadastrar as NCMs que faltam -> regra 1 (tributacao integral)
--    Base: NCM de todo produto ativo (nao so os que estao na carga de
--    hoje), para produto novo nao voltar a cair no mesmo buraco.
-- ---------------------------------------------------------------------
declare
  v_max integer;
  v_qtd integer;
begin
  for f in (select distinct to_number(codfilial) codfilial
              from msapolo_caixa
             where codfilial is not null
             order by 1) loop

    select nvl(max(id), 0) into v_max from msncm_ibs_cbs;

    insert into msncm_ibs_cbs (id, codfilial, idncm, ncm, id_ibs_cbs, modelo)
    select v_max + rownum,
           f.codfilial,
           (select min(x.idncm) from msncm x
             where lpad(trim(x.ncm),8,'0') = t.ncm8),
           t.ncm8,
           1,                       -- ms_trib_ibs_cbs.id 1 = CST 000 / 000001
           0
      from (select distinct lpad(trim(n.ncm),8,'0') ncm8
              from msproduto p, msncm n
             where n.idncm = p.idncm
               and p.dtexclusao is null
               and n.ncm is not null) t
     where not exists (select 1 from msncm_ibs_cbs x
                        where x.codfilial = f.codfilial
                          and x.modelo in (0, 65)
                          and x.codprod is null
                          and lpad(trim(x.ncm),8,'0') = t.ncm8);

    v_qtd := sql%rowcount;
    dbms_output.put_line('Filial '||f.codfilial||': '||v_qtd||' NCM(s) cadastrada(s) como tributacao integral');
  end loop;
end;
/

-- ---------------------------------------------------------------------
-- 4) CONFERENCIA - as duas consultas tem que voltar vazias/zeradas
-- ---------------------------------------------------------------------
-- 4a) nenhuma NCM de produto ativo pode ficar sem regra
select f.codfilial,
       (select count(*) from (
          select distinct lpad(trim(n.ncm),8,'0') ncm8
            from msproduto p, msncm n
           where n.idncm = p.idncm and p.dtexclusao is null) t
         where not exists (select 1 from msncm_ibs_cbs x
                            where x.codfilial = f.codfilial and x.modelo in (0,65)
                              and x.codprod is null
                              and lpad(trim(x.ncm),8,'0') = t.ncm8)) ncms_sem_regra
  from (select distinct to_number(codfilial) codfilial from msapolo_caixa) f
 order by 1;
-- Esperado: 0 em todas as filiais

-- 4b) nenhuma NCM pode ter duas regras
select codfilial, lpad(trim(ncm),8,'0') ncm, count(distinct id_ibs_cbs) regras
  from msncm_ibs_cbs where ncm is not null
 group by codfilial, lpad(trim(ncm),8,'0')
having count(distinct id_ibs_cbs) > 1;
-- Esperado: nenhuma linha

-- 4c) idncm preenchido nas linhas novas (aparece a mercadoria na rotina 2015)
select count(*) linhas_sem_idncm from msncm_ibs_cbs where idncm is null and ncm is not null;
-- Esperado: 0

commit;
-- (ou  rollback;  se 4a/4b nao baterem)


-- =====================================================================
-- 5) REVISAO DO CONTADOR - alimentos (capitulos 01 a 24)
-- ---------------------------------------------------------------------
-- 43 NCMs de alimento ficaram como tributacao integral. Se alguma for
-- cesta basica (Anexo I - aliquota reduzida a zero), e' so repontar:
--
--   update msncm_ibs_cbs set id_ibs_cbs = 14        -- 200003, Anexo I
--    where ncm is not null
--      and lpad(trim(ncm),8,'0') = '04012010';      -- exemplo: leite UHT
--   commit;
--
-- Lista para conferir:
select lpad(trim(x.ncm),8,'0') ncm,
       substr((select min(m.mercadoria) from msncm m
                where lpad(trim(m.ncm),8,'0') = lpad(trim(x.ncm),8,'0')),1,60) mercadoria,
       x.codfilial, x.id_ibs_cbs
  from msncm_ibs_cbs x
 where x.ncm is not null
   and to_number(substr(lpad(trim(x.ncm),8,'0'),1,2)) between 1 and 24
 order by 1, 3;

-- Regras disponiveis para repontar:
--   1  = 000 / 000001  tributacao integral
--   14 = 200 / 200003  alimentacao humana (Anexo I) - reducao 100%
--   45 = 200 / 200034  alimentos para consumo
--   46 = 200 / 200035  higiene pessoal
-- select id, cst, cclasstrib, nome_cclasstrib, ativo, indnfce,
--        ibsuf_predaliq, ibsuf_paliqefet, cbs_predaliq, cbs_paliqefet
--   from ms_trib_ibs_cbs where ativo = 1 order by cclasstrib;


-- =====================================================================
-- 6) RODAR A CARGA E CONFERIR
-- ---------------------------------------------------------------------
-- set serveroutput on
-- begin gerartabelatemporaria_apolo('1'); end;
-- /
-- begin gerartabelatemporaria_apolo('2'); end;
-- /
-- commit;
--
-- select codfilial, erro, count(*) from msapolo_erro
--  group by codfilial, erro order by 1, 3 desc;
-- Nao pode mais aparecer 'IBS/CBS: produto sem regra...' nem 'AVISO'.
