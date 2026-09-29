-- =====================================================================
-- FERNANDES.GERARTABELATEMPORARIA_APOLO
-- Versao 05/09/2026 - validacao de consistencia antes de mandar o produto
-- para o caixa.
--
-- O QUE MUDOU EM RELACAO A VERSAO ANTERIOR (so o final da procedure):
--   * msapolo_erro passou a ser limpa POR FILIAL (antes o delete apagava os
--     erros das outras filiais tambem).
--   * Todo produto inconsistente e' REGISTRADO em msapolo_erro e depois
--     REMOVIDO da carga em um unico delete ("se esta no erro, nao vai").
--     Antes 'sem codigo de barras' era removido sem registrar.
--   * Validacoes novas:
--       - NCM invalida (nula ou fora dos 8 digitos)
--       - IBS/CBS: sem regra / regra ambigua / regra inativa / regra que
--         nao vale para NFC-e / CST de aliquota reduzida sem os percentuais
--         de reducao (foi o que rejeitou os cupons 132-134 em 05/09/2026)
--   * Freio de seguranca: se a validacao de IBS/CBS derrubar mais de 20% da
--     carga, ela NAO remove nada - os erros ficam gravados com o prefixo
--     'AVISO (nao bloqueou)' e a carga sai inteira. Cadastro incompleto nao
--     pode esvaziar o caixa.
--   * O bloqueio de IBS/CBS pode ser desligado sem recompilar:
--       parametro APOLO_BLOQUEIO_IBSCBS = 'N'  (default 'S')
--
-- PRE-REQUISITO: hoje 2.694 produtos (226 NCMs) da filial 1 nao tem regra
-- de IBS/CBS. Enquanto isso nao for resolvido o freio acima vai disparar e
-- a validacao so avisa. Para resolver, escolha um dos dois:
--   a) preencher a regra geral da filial (vale para todo produto sem regra):
--        update msncm_ibs_cbs set modelo = 0, id_ibs_cbs = 1
--         where codfilial = 1 and ncm is null and codprod is null;
--        commit;
--   b) cadastrar as 226 NCMs que faltam na rotina 2015 - Reforma Tributaria.
--
-- Conferencia antes/depois (tem que voltar 0):
--   select count(*) from msapolo_produto_temp p
--    where p.codfilial = '1'
--      and not exists (select 1 from msncm_ibs_cbs n
--                       where n.codfilial = 1 and n.modelo in (0,65)
--                         and (n.codprod = p.codprod
--                          or (n.codprod is null and lpad(trim(n.ncm),8,'0') = lpad(trim(p.ncm),8,'0'))
--                          or (n.codprod is null and n.ncm is null)));
-- =====================================================================

CREATE OR REPLACE PROCEDURE FERNANDES.gerartabelatemporaria_apolo(p_codfilial varchar2) is
  v_numregiaoPreco integer;
  v_codConsumidor integer;
  v_qtMinAtac number;
  v_usaPrcUnico varchar2(2);
  v_codfilialPrc varchar2(2);
  v_codfilialTrib varchar2(2);
  v_numregiao integer;
  i integer;
  -- validacao de consistencia
  v_bloqIbsCbs  varchar2(20);
  v_qtIbsCbs    integer;
  v_qtCarga     integer;
  v_qtErro      integer;
begin
  select numregiao into v_numregiao from msfilial where codfilial = p_codfilial;

  dbms_output.put_line(to_char(current_timestamp,'hh24:mi:ss')||' - Filial para Preço ->'||p_codfilial);
  select lerparametro('USAR_PRECO_UNICO', p_codfilial, 'N') into v_usaPrcUnico from dual;
  v_codfilialPrc := p_codfilial;
  if v_usaPrcUnico = 'S' then
    select lerparametro('CODFILIAL_PRECO_UNICO', p_codfilial, 'N') into v_codfilialPrc from dual;
    dbms_output.put_line('Filial Usada para obter preco :'||v_codfilialPrc);
  end if;
  dbms_output.put_line('v_usaPrcUnico:'||v_usaPrcUnico);

  dbms_output.put_line(to_char(current_timestamp,'hh24:mi:ss')||' - Obtetendo os dados da filial');
  select numregiao_preco, codConsumidor, nvl(codfilialtrib, codfilial) into v_numregiaoPreco, v_codConsumidor, v_codfilialTrib
  from msfilial where codfilial = p_codfilial;
  dbms_output.put_line('v_numregiaoPreco:'||v_numregiaoPreco);
  dbms_output.put_line('v_codfilialTrib:'||v_codfilialTrib);
  dbms_output.put_line('v_codConsumidor:'||v_codConsumidor);

  dbms_output.put_line(to_char(current_timestamp,'hh24:mi:ss')||' - Deletando os dados Anteriores');
  -- 14/08/2026: delete por filial (nao apaga a carga das outras filiais)
  delete from msapolo_produto_temp where codfilial = p_codfilial;

  dbms_output.put_line(to_char(current_timestamp,'hh24:mi:ss')||' - Inserindo o Cadastro de Produtos');
  insert into msapolo_produto_temp
  ( codfilial
    ,numregiao
    ,codprod
    ,codbarra
    ,descricao
    ,unidade
    ,embalagem
    ,ncm
    ,extipi
    ,cest
    ,prod_origem
    ,ean_Valido
    ,permite_dig_preco
    ,permite_dig_desc
    ,permite_dig_qtde
    ,permite_dig_cod
    ,pesoobrigatorio
    ,pesovariavel
    ,codecf
    ,codprodprinc
    ,ID
    ,perc_lei_transparencia
    ,qtunit
       ) select
       p_codfilial
       ,v_numregiao
       ,P.codprod
       ,nvl(b.codbarra,p.codbarra) codbarra
       ,nvl(b.descricao, P.descricao) descricao
       ,nvl(b.unidade, P.unidade) unidade
       ,nvl(p.embalagem,'Unidade')
       ,n.ncm
       ,n.ex
       ,n.cest
       ,nvl(p.origem,'0') prod_origem
       ,valida_ean(remover_zeros_esquerda(nvl(b.codbarra,p.codbarra))) ean_Valido
       -- 14/08/2026: defaults que estavam na view msapolo_produtos
       ,nvl(P.permite_dig_preco,'N')
       ,nvl(P.permite_dig_desc,'S')
       ,nvl(P.permite_dig_qtde,'S')
       ,nvl(P.permite_dig_codigo,'S')
       ,nvl(P.pesoobrigatorio,'N')
       ,nvl(P.pesovariavel,'N')
       ,'II' codecf
       ,nvl(p.codprodprinc,p.codprod)
       ,0 ID
       ,n.aliqimp
       ,coalesce(b.qtunit, p.qtunit,1)
      from
        msproduto p
        ,msncm n
        ,(select b.codprod, b.codbarra, b.qtunit, b.descricao, b.unidade from mscodbarra b union
          select p.codprod, p.codbarra, p.qtunit, p.descricao, p.unidade from msproduto p where p.dtexclusao is null
          and p.codbarra not in (select x.codbarra from mscodbarra x)) b
      where  n.idncm = p.idncm
        and p.codprod = b.codprod
        and p.dtexclusao is null
        and (
          select count(*) from msprecos t where
          t.codprod = p.codprod
          and t.codfilial = v_codfilialPrc
          and t.numregiao = v_numregiaoPreco
        )>0;
  dbms_output.put_line('Total de registros: '||sql%rowcount);


  dbms_output.put_line(to_char(current_timestamp,'hh24:mi:ss')||' - Setando os Precos');
  update msapolo_produto_temp p set
    (codbarra
     ,ean_Valido
     ,id
     ,pcusto
     ,pvenda
     ,pvendaatac
     ,Poferta
     ,dtfimoferta
     ,qtminiatac
     ,maxperdesc
     ,versaoreg
     )=(select
          remover_zeros_esquerda(nvl(t.codbarra,p.codbarra))
          ,valida_ean(remover_zeros_esquerda(nvl(t.codbarra,p.codbarra))) ean_Valido
          ,id
          ,pcusto
          ,pvenda
          ,decode(nvl(pvendaatac,0),0,pvenda,pvendaatac) pvendaatac
          ,poferta
          ,dtfimoferta
          ,qtminiatac
          ,maxperdesc
          ,versaoreg
         from msprecos t
         where
           t.codprod       = p.codprod
           and t.codbarra  = p.codbarra
           and t.codfilial = v_codfilialPrc
           and t.numregiao = v_numregiaoPreco
           and rownum      = 1
           )
   where p.codfilial = p_codfilial;   -- 14/08/2026

  dbms_output.put_line(to_char(current_timestamp,'hh24:mi:ss')||' - Atualizando quantidade mínima de atacado');
  for reg in (
    select po.codprod, po.codprodprinc, ptp.qtminiatac, pto.id
    from msprecos co
      ,msproduto po
      ,msproduto pp
      ,msprecos cp
      ,msapolo_produto_temp ptp
      ,msapolo_produto_temp pto
    where po.codprodprinc = pp.codprod
    and pp.codprod = cp.codprod
    and pp.codbarra  = cp.codbarra
    and ptp.id = cp.id
    and co.codprod = po.codprod
    and co.codbarra = po.codbarra
    and co.codfilial = cp.codfilial
    and co.numregiao = cp.numregiao
    and pto.id = co.id
    and po.codprod <> po.codprodprinc
    and nvl(po.codprodprinc,0)<>0
    and cp.codfilial = p_codfilial
    and cp.numregiao = v_numregiaoPreco
  ) loop
    update msapolo_produto_temp p set p.qtminiatac = reg.qtminiatac where p.id = reg.id;
  end loop;

  dbms_output.put_line(to_char(current_timestamp,'hh24:mi:ss')||' - Setando o Codigo da Tributacao');
  update msapolo_produto_temp p set
    codtrib = (select min(x.codtrib_icms) from mstrib x
               where x.codfilial = p.codfilial
                 and x.numregiao = p.numregiao
                 --and x.codoper = 'S'
                 and (x.codprod = p.codprod  or  x.codprod is null  )
                  and (x.ncm     = p.ncm  or  x.ncm is null  ) )
  where codfilial  = p_codfilial;

  dbms_output.put_line(to_char(current_timestamp,'hh24:mi:ss')||' - Setando os Impostos');
  update msapolo_produto_temp set
  (aliqicms
  ,icms_cst
  ,cfop
  ,cbenef
  ,csosn
  ,icms_percbasered
  ,pis_cst
  ,cofins_cst
  ,aliqpis
  ,aliqcofins
  ,vlbaseicms
  ,vlicms
  )=
  (select
    aliqicms
    ,sittribut_icms
    ,cfop_sai
    ,cbenef
    ,csosn
    ,icms_percbasered
    ,pis_cst
    ,cofins_cst
    ,aliqpis
    ,aliqcofins
    ,calc_baseicms( 1, aliqicms ,icms_percbasered ,'N' ,0)
    ,calc_vlicms(calc_baseicms( 1, aliqicms ,icms_percbasered ,'N' ,0),aliqicms)
   from mstribut t where t.codtrib = msapolo_produto_temp.codtrib)
   where codfilial = p_codfilial;   -- 14/08/2026

  --PIS/COFINS
  update msapolo_produto_temp set
    codtribpiscofins = obter_tributacao_piscofins( v_codfilialTrib, 'S', codprod, v_codConsumidor)
   where codfilial = p_codfilial;   -- 14/08/2026

  update msapolo_produto_temp set
  (pis_cst
  ,pis_ppis
  ,pis_qBCProd
  ,pis_vAliqProd
  ,pisst_ppis
  ,PISST_qBCProd
  ,PISST_vAliqProd
  ,cofins_cst
  ,cofins_pcofins
  ,COFINS_qBCProd
  ,COFINS_vAliqProd
  ,COFINSST_pCOFINS
  ,COFINSST_qBCProd
  ,COFINSST_vAliqProd
  ,pis_vbc
  ,cofins_vbc
  ,pis_vpis
  ,cofins_vcofins
   )=
  (select
    t.sittribut_pis
    ,t.aliqpis
    ,0 pis_qBCProd
    ,0 pis_vAliqProd
    ,t.aliqpisst
    ,0 PISST_qBCProd
    ,0 PISST_vAliqProd
    ,COFINS_CST
    ,ALIQCOFINS
    ,0 COFINS_qBCProd
    ,0 COFINS_vAliqProd
    ,COFINSST_pCOFINS
    ,0 COFINSST_qBCProd
    ,0 COFINSST_vAliqProd
    ,calc_basepis(1, 0, t.aliqpis)
    ,calc_basecofins(1, 0, t.aliqcofins)
    ,calc_vlpis(calc_basepis(1, 0, t.aliqpis), t.aliqpis)
    ,calc_vlcofins(calc_basecofins(1, 0, t.aliqcofins), t.aliqcofins)
  from mstribpiscofins t where t.codtribpiscofins = msapolo_produto_temp.codtribpiscofins)
  where codfilial = p_codfilial;   -- 14/08/2026

  -- 14/08/2026: estoque disponivel (regra que estava na view msapolo_produtos)
  dbms_output.put_line(to_char(current_timestamp,'hh24:mi:ss')||' - Setando o Estoque Disponivel');
  update msapolo_produto_temp p set
    qtdisponivel = (select x.qtestger - nvl(x.qtreserv,0) - nvl(x.qtbloqueada,0)
                      from msest x
                     where x.codprod = p.codprod
                       and x.codfilial = p.codfilial)
  where p.codfilial = p_codfilial;

  -- ===================================================================
  -- 05/09/2026 - CONSISTENCIA DA CARGA
  -- Primeiro registra tudo em msapolo_erro, depois tira da carga o que
  -- foi registrado. Produto inconsistente no caixa nao e' venda perdida
  -- de um item: e' cupom rejeitado pela SEFAZ e caixa parado.
  -- ===================================================================
  dbms_output.put_line(to_char(current_timestamp,'hh24:mi:ss')||' - Validando a carga');

  select count(*) into v_qtCarga from msapolo_produto_temp where codfilial = p_codfilial;

  -- so os erros DESTA filial (antes o delete limpava a tabela inteira)
  delete from msapolo_erro where codfilial = p_codfilial;

  insert into msapolo_erro (codprod, codfilial, codbarra, dthora, erro)
  select codprod, codfilial, codbarra, sysdate, 'sem tributação'
    from msapolo_produto_temp
   where codfilial = p_codfilial
     and codtrib is null;

  insert into msapolo_erro (codprod, codfilial, codbarra, dthora, erro)
  select codprod, codfilial, codbarra, sysdate, 'preco de venda zerado'
    from msapolo_produto_temp
   where codfilial = p_codfilial
     and nvl(pvenda,0) = 0;

  insert into msapolo_erro (codprod, codfilial, codbarra, dthora, erro)
  select codprod, codfilial, codbarra, sysdate, 'sem codigo de barras'
    from msapolo_produto_temp
   where codfilial = p_codfilial
     and codbarra is null;

  -- NCM e' obrigatoria na NFC-e e tem exatamente 8 digitos
  insert into msapolo_erro (codprod, codfilial, codbarra, dthora, erro)
  select codprod, codfilial, codbarra, sysdate,
         'NCM invalida ('||nvl(ncm,'nula')||') - conferir msncm'
    from msapolo_produto_temp
   where codfilial = p_codfilial
     and (ncm is null
          or length(trim(ncm)) <> 8
          or trim(translate(ncm, '0123456789', ' ')) is not null);

  -- Reforma tributaria: a regra de IBS/CBS do item e' escolhida da mais
  -- especifica para a mais generica (codprod -> ncm -> geral), igual ao
  -- PDV faz em ResolverIBSCBS. Sem regra utilizavel a SEFAZ rejeita o
  -- cupom inteiro. As mensagens comecam com 'IBS/CBS:' de proposito - o
  -- freio de seguranca logo abaixo se apoia nisso.
  insert into msapolo_erro (codprod, codfilial, codbarra, dthora, erro)
  with regras as (
    select case when n.codprod is not null then 1
                when n.ncm     is not null then 2
                else 3 end                                     prioridade,
           n.codprod                                           codprod,
           lpad(trim(n.ncm), 8, '0')                           ncm8,
           t.id                                                id_regra,
           t.cst                                               cst,
           t.cclasstrib                                        cclasstrib,
           nvl(t.ativo, 0)                                     ativo,
           nvl(t.indnfce, 0)                                   indnfce,
           nvl(t.ibsuf_predaliq,0)  + nvl(t.ibsuf_paliqefet,0)
         + nvl(t.ibsmun_predaliq,0) + nvl(t.ibsmun_paliqefet,0)
         + nvl(t.cbs_predaliq,0)    + nvl(t.cbs_paliqefet,0)    reducao
      from msncm_ibs_cbs n, ms_trib_ibs_cbs t
     where t.id = n.id_ibs_cbs
       and n.codfilial = to_number(p_codfilial)
       and n.modelo in (0, 65)          -- mesmo filtro da carga do PDV
  ),
  casadas as (
    select p.codprod, p.codbarra, p.ncm,
           r.prioridade, r.id_regra, r.cst, r.cclasstrib,
           r.ativo, r.indnfce, r.reducao,
           min(r.prioridade) over (partition by p.codprod, nvl(p.codbarra,'#')) melhor
      from msapolo_produto_temp p, regras r
     where p.codfilial = p_codfilial
       and (   (r.prioridade = 1 and r.codprod = p.codprod)
            or (r.prioridade = 2 and r.ncm8 = lpad(trim(p.ncm), 8, '0'))
            or (r.prioridade = 3))
  ),
  escolhida as (
    select codprod, nvl(codbarra,'#') codbarra_k,
           count(distinct id_regra)                                    qt_regras,
           min(cst)        keep (dense_rank first order by id_regra)   cst,
           min(cclasstrib) keep (dense_rank first order by id_regra)   cclasstrib,
           min(ativo)      keep (dense_rank first order by id_regra)   ativo,
           min(indnfce)    keep (dense_rank first order by id_regra)   indnfce,
           min(reducao)    keep (dense_rank first order by id_regra)   reducao
      from casadas
     where prioridade = melhor
     group by codprod, nvl(codbarra,'#')
  )
  select p.codprod, p.codfilial, p.codbarra, sysdate,
         'IBS/CBS: '||
         case
           when e.codprod is null then
             'produto sem regra para a NCM '||p.ncm||
             ' - cadastrar em msncm_ibs_cbs (ou preencher a regra geral da filial)'
           when e.qt_regras > 1 then
             'NCM '||p.ncm||' com '||e.qt_regras||
             ' regras diferentes em msncm_ibs_cbs - a tributacao sai indefinida'
           when e.ativo = 0 then
             'cClassTrib '||e.cclasstrib||' esta inativa em ms_trib_ibs_cbs'
           when e.indnfce = 0 then
             'cClassTrib '||e.cclasstrib||' nao vale para NFC-e (INDNFCE = 0)'
           else
             'cClassTrib '||e.cclasstrib||' (CST '||e.cst||') e de aliquota reduzida'||
             ' e ms_trib_ibs_cbs esta sem pRedAliq/pAliqEfet'
         end
    from msapolo_produto_temp p
         left join escolhida e
           on e.codprod    = p.codprod
          and e.codbarra_k = nvl(p.codbarra,'#')
   where p.codfilial = p_codfilial
     and (   e.codprod is null
          or e.qt_regras > 1
          or e.ativo   = 0
          or e.indnfce = 0
          or (e.cst in ('200','220','221','222') and e.reducao = 0));

  v_qtIbsCbs := sql%rowcount;
  dbms_output.put_line('  IBS/CBS inconsistente: '||v_qtIbsCbs||' de '||v_qtCarga);

  -- Freio: cadastro de IBS/CBS incompleto nao pode esvaziar o caixa. Acima
  -- de 20% da carga (ou com o parametro desligado) o erro fica registrado
  -- como aviso e o produto continua indo - a venda vai ser rejeitada pela
  -- SEFAZ, mas isso e' problema conhecido, caixa sem produto e' pior.
  select lerparametro('APOLO_BLOQUEIO_IBSCBS', p_codfilial, 'S') into v_bloqIbsCbs from dual;

  if v_bloqIbsCbs <> 'S' or (v_qtCarga > 0 and v_qtIbsCbs > v_qtCarga * 0.2) then
    update msapolo_erro
       set erro = 'AVISO (nao bloqueou) - '||erro
     where codfilial = p_codfilial
       and erro like 'IBS/CBS:%';
    if v_bloqIbsCbs <> 'S' then
      dbms_output.put_line('  IBS/CBS: bloqueio desligado (APOLO_BLOQUEIO_IBSCBS = '||v_bloqIbsCbs||')');
    else
      dbms_output.put_line('  IBS/CBS: mais de 20% da carga inconsistente - NAO bloqueou,'||
                           ' so registrou. Conferir msncm_ibs_cbs da filial '||p_codfilial);
    end if;
  end if;

  -- Tira da carga tudo que foi registrado como erro (avisos ficam)
  delete from msapolo_produto_temp p
   where p.codfilial = p_codfilial
     and exists (select 1
                   from msapolo_erro e
                  where e.codfilial = p.codfilial
                    and e.codprod   = p.codprod
                    and nvl(e.codbarra,'#') = nvl(p.codbarra,'#')
                    and e.erro not like 'AVISO%');
  dbms_output.put_line('  Registros removidos da carga: '||sql%rowcount);

  select count(*) into v_qtErro from msapolo_erro where codfilial = p_codfilial;
  dbms_output.put_line('  Registros em msapolo_erro: '||v_qtErro);

  -- 14/08/2026: versionar a carga inteira; o PDV usa versaoreg para o
  -- sync incremental - sem isso, alteracao de cadastro so chega em carga geral
  update msapolo_produto_temp set versaoreg = sysdate where codfilial = p_codfilial;

  select count(*) into i from msapolo_produto_temp where codfilial=p_codfilial;
  dbms_output.put_line('Total de Registros da msapolo_produto_temp '||i);

  dbms_output.put_line(to_char(current_timestamp,'hh24:mi:ss')||' - Final ');

end;
/

-- =====================================================================
-- CONFERENCIA depois de rodar a carga
-- =====================================================================
-- set serveroutput on
-- begin gerartabelatemporaria_apolo('1'); end;
-- /
-- commit;
--
-- select erro, count(*) from msapolo_erro where codfilial = '1'
--  group by erro order by 2 desc;
--
-- select * from msapolo_erro where codfilial = '1' and erro like 'IBS/CBS%'
--  order by codprod fetch first 50 rows only;
