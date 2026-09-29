unit uDmApoloWeb;

interface

uses
  System.SysUtils, System.Classes, System.IniFiles,System.UITypes, Uni, UniProvider, SQLiteUniProvider, OracleUniProvider,
  ACBrBase, ACBrDFe, ACBrDFeSSL,ACBrNFe, ACBrBAL, ACBrLCB, pcnConversao, pcnConversaoNFe,DBAccess,ACBrDFeReport,uSQLiteDB,
  uConstantesWeb, uTypesApoloWeb, uTEF, Data.DB, ACBrDFeDANFeReport, ACBrNFeDANFEClass, ACBrNFCeDANFeFPDF,
  ACBrPosPrinter, ACBrNFeDANFeESCPOS;


type
  TDmApoloWeb = class(TDataModule)
    // Conexao Oracle (online)
    UniConnOracle: TUniConnection;
    // Conexao SQLite (offline/local)
    UniConnSQLite: TUniConnection;
    // ACBr NFCe
    ACBrNFe: TACBrNFe;
    // ACBr Balanca e Leitor
    ACBrBAL: TACBrBAL;
    ACBrLCB: TACBrLCB;
    ACBrNFeDANFCe: TACBrNFCeDANFeFPDF;
    procedure DataModuleCreate(Sender: TObject);
    procedure DataModuleDestroy(Sender: TObject);
  private
    FSQLiteDB: TSQLiteDB;
    FConectadoOracle: Boolean;
    FCodFilial: string;
    FNumCaixa: Integer;
    FNumSerieHD: string;
    FTEFHabilitado: Boolean;
    FTEFUrl: string;
    FTEFConfig: TTEFConfig;

    // Impressao do cupom: SUMATRA (PDF via app externo) ou ESCPOS (direto na termica)
    FModoImpressao: string;
    FImpressoraCupom: string;
    FEscPosModelo: string;
    FEscPosPorta: string;
    FEscPosColunas: Integer;
    FPosPrinter: TACBrPosPrinter;
    FDANFeESCPOS: TACBrNFeDANFeESCPOS;

    function GetImpressaoEscPos: Boolean;
    procedure ConfigurarImpressaoCupom;

    procedure ConfigurarConexaoOracle;

    // Parametrizacao via Oracle
    function ObterSerialHD: string;
    procedure CarregarParametrosCaixa;
    function CarregarParametrosFilial: TParametrosFilial;
    procedure ConfigurarACBrNFCe(const AParams: TParametrosFilial);
  public
    procedure CarregarConfiguracao;
    procedure ConectarOracle;
    procedure DesconectarOracle;
    function TestarConexaoOracle: Boolean;

    // Reaplica certificado/CSC no ACBr (usado quando a carga geral rebaixa o PFX)
    procedure RecarregarConfiguracaoNFCe;

    // Queries Oracle
    function ExecutarSelectOracle(const ASQL: string): TUniQuery;
    procedure ExecutarSQLOracle(const ASQL: string);

    property SQLiteDB: TSQLiteDB read FSQLiteDB;
    property ConectadoOracle: Boolean read FConectadoOracle;
    property CodFilial: string read FCodFilial;
    property NumCaixa: Integer read FNumCaixa;
    property NumSerieHD: string read FNumSerieHD;
    property TEFHabilitado: Boolean read FTEFHabilitado;
    property TEFUrl: string read FTEFUrl;
    // Config completa do TEF (modo http ou arquivo) - ver [TEF] no apoloweb.ini
    property TEFConfig: TTEFConfig read FTEFConfig;

    // Reaplica [impressao] do apoloweb.ini (usado pela tela de parametros)
    procedure RecarregarConfiguracaoImpressao;
    // Modelos ESC/POS aceitos pelo ACBrPosPrinter (para o combo da tela)
    function ModelosPosPrinter: TArray<string>;

    // Impressao do cupom
    property ImpressaoEscPos: Boolean read GetImpressaoEscPos;
    property ModoImpressao: string read FModoImpressao;
    property ImpressoraCupom: string read FImpressoraCupom;
    property EscPosModelo: string read FEscPosModelo;
    property EscPosPorta: string read FEscPosPorta;
    property EscPosColunas: Integer read FEscPosColunas;
    property PosPrinter: TACBrPosPrinter read FPosPrinter;
  end;

var
  DmApoloWeb: TDmApoloWeb;

implementation

{$R *.dfm}

uses
  Winapi.Windows, System.Win.Registry, System.TypInfo, Vcl.Dialogs, uFrmConfigConexao;

// =========================================================================
// LIFECYCLE
// =========================================================================

procedure TDmApoloWeb.DataModuleCreate(Sender: TObject);
var
  LParams: TParametrosFilial;
  LUsarCache: Boolean;
begin
  SetDllDirectory('c:\colosso\prod\dlls');
  FConectadoOracle := False;
  FNumCaixa := 0;
  FCodFilial := '';
  LUsarCache := False;

  // 1. Inicializar SQLite
  // Falha aqui nao pode seguir adiante: o VCL engole a excecao do OnCreate do
  // DataModule e o app subiria sem bridge, transformando toda acao do JS em
  // Access Violation. Melhor abortar com o motivo na tela.
  FSQLiteDB := TSQLiteDB.Create(ARQUIVO_SQLITE);
  try
    FSQLiteDB.CriarBanco;
  except
    on E: Exception do
    begin
      MessageDlg('Falha ao abrir o banco local:' + sLineBreak +
        ARQUIVO_SQLITE + sLineBreak + sLineBreak + E.Message + sLineBreak + sLineBreak +
        'Verifique se outra copia do ApoloWeb (ou um visualizador de SQLite) ' +
        'esta com o arquivo aberto.', mtError, [mbOK], 0);
      Halt(2);
    end;
  end;

  // 2. Obter serial do HD
  FNumSerieHD := ObterSerialHD;
  if FNumSerieHD <> '' then
    FSQLiteDB.SalvarEstado(KEY_HD_SERIAL, FNumSerieHD);

  // 3. Carregar configuracao de conexao (apoloweb.ini: Oracle, TEF, impressao)
  CarregarConfiguracao;

  // 4. Tentar conectar ao Oracle e carregar parametros
  try
    ConectarOracle;
    if FConectadoOracle then
    begin
      // 5. Identificar caixa pelo HD serial
      CarregarParametrosCaixa;

      // 6. Carregar dados da filial (certificado BLOB, logo, CSC, etc.)
      LParams := CarregarParametrosFilial;

      // 7. Configurar ACBr com dados do Oracle
      ConfigurarACBrNFCe(LParams);
    end
    else
      LUsarCache := True;
  except
    on E: Exception do
    begin
      // Oracle indisponivel - tentar usar cache local
      LUsarCache := True;
    end;
  end;

  // Fallback: usar dados do SQLite/arquivos locais se Oracle indisponivel
  if LUsarCache then
  begin
    FCodFilial := FSQLiteDB.ObterEstado(KEY_CODFILIAL, '');
    FNumCaixa := StrToIntDef(FSQLiteDB.ObterEstado(KEY_NUMCAIXA, '0'), 0);

    // Se ja tem certificado local e dados no SQLite, configurar ACBr com cache
    if FileExists(ARQUIVO_CERTIFICADO) and (FCodFilial <> '') then
    begin
      LParams := Default(TParametrosFilial);
      LParams.CodFilial := FCodFilial;
      LParams.SenhaCertificado := FSQLiteDB.ObterEstado('SENHA_CERTIFICADO', '');
      LParams.CSC := FSQLiteDB.ObterEstado('CSC', '');
      LParams.IDCSC := FSQLiteDB.ObterEstado('IDCSC', '');
      LParams.AmbienteNFe := FSQLiteDB.ObterEstado('AMBIENTE_NFE', '2');
      LParams.UFWebService := FSQLiteDB.ObterEstado('UF_WEBSERVICE', 'SP');
      ConfigurarACBrNFCe(LParams);
    end
    else
    begin
      // Sem cache e sem Oracle: oferecer tela de configuracao
      if AbrirConfigConexao then
      begin
        // Usuario configurou conexao, tentar novamente
        CarregarConfiguracao;
        try
          ConectarOracle;
          if FConectadoOracle then
          begin
            CarregarParametrosCaixa;
            LParams := CarregarParametrosFilial;
            ConfigurarACBrNFCe(LParams);
          end;
        except
          on E: Exception do
            MessageDlg('Falha ao conectar: ' + E.Message, mtError, [mbOK], 0);
        end;
      end;
    end;
  end;
end;

procedure TDmApoloWeb.DataModuleDestroy(Sender: TObject);
begin
  DesconectarOracle;
  FSQLiteDB.Free;
end;

// =========================================================================
// HD SERIAL
// =========================================================================

function TDmApoloWeb.ObterSerialHD: string;
var
  LSerial: DWORD;
  LMaxLen, LFlags: DWORD;
  LVolName, LFSName: array[0..255] of Char;
begin
  if GetVolumeInformation('C:\', LVolName, 256, @LSerial, LMaxLen, LFlags, LFSName, 256) then
    Result := IntToStr(LSerial)
  else
    Result := '';
end;

// =========================================================================
// PARAMETRIZACAO VIA ORACLE
// =========================================================================

procedure TDmApoloWeb.CarregarParametrosCaixa;
var
  LQuery: TUniQuery;
begin
  if FNumSerieHD = '' then
    raise Exception.Create('Nao foi possivel obter o numero de serie do HD.');

  LQuery := TUniQuery.Create(nil);
  try
    LQuery.Connection := UniConnOracle;
    LQuery.SQL.Text :=
      'SELECT codfilial, numcaixa, numseriehd ' +
      'FROM msapolo_caixa ' +
      'WHERE numseriehd = :numseriehd';
    LQuery.ParamByName('numseriehd').AsString := FNumSerieHD;
    LQuery.Open;

    if LQuery.IsEmpty then
      raise Exception.Create(
        'Caixa nao cadastrado para este HD.' + sLineBreak +
        'Serial HD: ' + FNumSerieHD + sLineBreak +
        'Cadastre o caixa na tabela msapolo_caixa.');

    FCodFilial := LQuery.FieldByName('codfilial').AsString;
    FNumCaixa := LQuery.FieldByName('numcaixa').AsInteger;

    // Salvar no SQLite para uso offline
    FSQLiteDB.SalvarEstado(KEY_CODFILIAL, FCodFilial);
    FSQLiteDB.SalvarEstado(KEY_NUMCAIXA, IntToStr(FNumCaixa));
  finally
    LQuery.Free;
  end;
end;

function TDmApoloWeb.CarregarParametrosFilial: TParametrosFilial;
var
  LQuery: TUniQuery;
  LBlobStream: TStream;
  LFileStream: TFileStream;
begin
  Result := Default(TParametrosFilial);

  LQuery := TUniQuery.Create(nil);
  try
    LQuery.Connection := UniConnOracle;
    LQuery.SQL.Text :=
      'SELECT f.codfilial, f.razaosocial, f.nome_fantasia, f.cnpj, f.ie, ' +
      'f.endereco, f.cep, f.bairro, f.ender_numero, f.cidade, f.codcidade, ' +
      'f.uf, f.fone, ' +
      'f.csc, f.idcsc, f.senha_certificado, f.ambiente_nfe, ' +
      'f.uf_web_service_nfe, f.codconsumidor, f.crt, ' +
      'f.certificado_digital, f.logo_nfe ' +
      'FROM msfilial f WHERE f.codfilial = :codfilial';
    LQuery.ParamByName('codfilial').AsString := FCodFilial;
    LQuery.Open;

    if LQuery.IsEmpty then
      raise Exception.Create(
        'Filial nao encontrada: ' + FCodFilial + sLineBreak +
        'Verifique a tabela msfilial.');

    // Preencher record com dados da filial
    Result.CodFilial := LQuery.FieldByName('codfilial').AsString;
    Result.RazaoSocial := LQuery.FieldByName('razaosocial').AsString;
    Result.Fantasia := LQuery.FieldByName('nome_fantasia').AsString;
    Result.CNPJ := LQuery.FieldByName('cnpj').AsString;
    Result.IE := LQuery.FieldByName('ie').AsString;
    Result.Endereco := LQuery.FieldByName('endereco').AsString;
    Result.CEP := LQuery.FieldByName('cep').AsString;
    Result.Bairro := LQuery.FieldByName('bairro').AsString;
    Result.Numero := LQuery.FieldByName('ender_numero').AsString;
    Result.Cidade := LQuery.FieldByName('cidade').AsString;
    Result.CodCidade := LQuery.FieldByName('codcidade').AsString;
    Result.UF := LQuery.FieldByName('uf').AsString;
    Result.Fone := LQuery.FieldByName('fone').AsString;
    Result.CSC := LQuery.FieldByName('csc').AsString;
    Result.IDCSC := LQuery.FieldByName('idcsc').AsString;
    Result.SenhaCertificado := LQuery.FieldByName('senha_certificado').AsString;
    Result.AmbienteNFe := LQuery.FieldByName('ambiente_nfe').AsString;
    Result.UFWebService := LQuery.FieldByName('uf_web_service_nfe').AsString;
    // Sem uf_web_service_nfe preenchida, usar a UF da propria filial
    if Trim(Result.UFWebService) = '' then
      Result.UFWebService := Result.UF;
    Result.CodConsumidor := LQuery.FieldByName('codconsumidor').AsInteger;
    Result.CRT := LQuery.FieldByName('crt').AsInteger;
    Result.RegimeTributario := LQuery.FieldByName('crt').AsInteger;

    // Extrair certificado BLOB -> arquivo PFX
    if not LQuery.FieldByName('certificado_digital').IsNull then
    begin
      LBlobStream := LQuery.CreateBlobStream(
        LQuery.FieldByName('certificado_digital'), bmRead);
      try
        if LBlobStream.Size > 0 then
        begin
          LFileStream := TFileStream.Create(ARQUIVO_CERTIFICADO, fmCreate);
          try
            LFileStream.CopyFrom(LBlobStream, LBlobStream.Size);
          finally
            LFileStream.Free;
          end;
        end;
      finally
        LBlobStream.Free;
      end;
    end;

    // Extrair logo BLOB -> arquivo BMP (se existir)
    if not LQuery.FieldByName('logo_nfe').IsNull then
    begin
      LBlobStream := LQuery.CreateBlobStream(
        LQuery.FieldByName('logo_nfe'), bmRead);
      try
        if LBlobStream.Size > 0 then
        begin
          LFileStream := TFileStream.Create(ARQUIVO_LOGO, fmCreate);
          try
            LFileStream.CopyFrom(LBlobStream, LBlobStream.Size);
          finally
            LFileStream.Free;
          end;
        end;
      finally
        LBlobStream.Free;
      end;
    end;

    // Atualizar tabela empresa no SQLite
    FSQLiteDB.ExecutarSQL('DELETE FROM empresa');
    FSQLiteDB.ExecutarSQL(
      'INSERT INTO empresa (id, razao_social, fantasia, cnpj, ie, ' +
      'endereco, numero, complemento, bairro, cidade, uf, cep, ' +
      'cod_cidade_ibge, regime_tributario, fone) ' +
      'VALUES (1, :p0, :p1, :p2, :p3, :p4, :p5, :p6, :p7, :p8, :p9, :p10, :p11, :p12, :p13)',
      [Result.RazaoSocial, Result.Fantasia, Result.CNPJ, Result.IE,
       Result.Endereco, Result.Numero, '', Result.Bairro,
       Result.Cidade, Result.UF, Result.CEP,
       Result.CodCidade, Result.RegimeTributario, Result.Fone]
    );

    // Salvar dados no SQLite para cache offline
    FSQLiteDB.SalvarEstado('SENHA_CERTIFICADO', Result.SenhaCertificado);
    FSQLiteDB.SalvarEstado('CSC', Result.CSC);
    FSQLiteDB.SalvarEstado('IDCSC', Result.IDCSC);
    FSQLiteDB.SalvarEstado('AMBIENTE_NFE', Result.AmbienteNFe);
    FSQLiteDB.SalvarEstado('UF_WEBSERVICE', Result.UFWebService);
    FSQLiteDB.SalvarEstado(KEY_CODCONSUMIDOR, IntToStr(Result.CodConsumidor));
  finally
    LQuery.Free;
  end;
end;

// =========================================================================
// CONFIGURACAO
// =========================================================================

procedure TDmApoloWeb.CarregarConfiguracao;
begin
  ConfigurarConexaoOracle;
end;

procedure TDmApoloWeb.ConfigurarConexaoOracle;
var
  ini: TIniFile;
begin
  ini:=TIniFile.Create('c:\apolo\apoloweb.ini');
  try
    UniConnOracle.ProviderName := 'Oracle';
    UniConnOracle.Server   := ini.ReadString('oracle','server','');
    UniConnOracle.Username := ini.ReadString('oracle','username','');
    UniConnOracle.Password := ini.ReadString('oracle','password','');
    UniConnOracle.LoginPrompt := False;
    If Pos(':',UniConnOracle.Server)>0 Then
      UniConnOracle.SpecificOptions.Values['Direct']:='True';
    // TEF - dois modos de integracao:
    //   modo=http    -> POST JSON no TefGpAPI (url)
    //   modo=arquivo -> intercambio intpos.001/intpos.sts nas pastas Req/Resp
    //                   do gerenciador Tef_Dial/GetPay (dispensa a API HTTP)
    FTEFHabilitado := ini.ReadBool('TEF','habilitado', False);
    FTEFUrl := ini.ReadString('TEF','url', TEF_URL_PADRAO);

    FTEFConfig.Habilitado := FTEFHabilitado;
    FTEFConfig.Modo       := TEFModoFromString(
                               ini.ReadString('TEF','modo', TEF_MODO_HTTP));
    FTEFConfig.Url        := FTEFUrl;
    FTEFConfig.PastaReq   := ini.ReadString('TEF','pasta_req', TEF_PASTA_REQ_PADRAO);
    FTEFConfig.PastaResp  := ini.ReadString('TEF','pasta_resp', TEF_PASTA_RESP_PADRAO);
    FTEFConfig.TimeoutSeg := ini.ReadInteger('TEF','timeout', TEF_TIMEOUT_PADRAO);
    FTEFConfig.Debug      := ini.ReadBool('TEF','debug', False);
    FTEFConfig.Identificacao := FNumCaixa;

    // QR Code do PIX pelo TEF: pinpad (a adquirente desenha no visor) ou tela
    // (o PDV exibe o BR Code que o gerenciador devolver). Ver uTEF.pas.
    FTEFConfig.PixQr        := TEFPixQrFromString(
                                 ini.ReadString('TEF','pix_qr', TEF_PIX_QR_PADRAO));
    FTEFConfig.PixQrCampos  := ini.ReadString('TEF','pix_qr_campos', TEF_PIX_QR_AUTO);
    FTEFConfig.PixQrChaves  := ini.ReadString('TEF','pix_qr_chaves', TEF_PIX_QR_AUTO);

    // Impressao do cupom (DANFCe)
    //   modo=SUMATRA : gera PDF e imprime via SumatraPDF (fallback PrintCupon)
    //   modo=ESCPOS  : imprime direto na termica via ACBrPosPrinter (sem PDF)
    FModoImpressao   := UpperCase(Trim(ini.ReadString('impressao','modo','SUMATRA')));
    FImpressoraCupom := ini.ReadString('impressao','impressora','');
    FEscPosModelo    := ini.ReadString('impressao','escpos_modelo','ppEscPosEpson');
    FEscPosPorta     := ini.ReadString('impressao','escpos_porta','');
    FEscPosColunas   := ini.ReadInteger('impressao','escpos_colunas', 48);
  finally
    ini.Free;
  end;
end;

function TDmApoloWeb.GetImpressaoEscPos: Boolean;
begin
  Result := FModoImpressao = 'ESCPOS';
end;

procedure TDmApoloWeb.ConfigurarImpressaoCupom;
var
  LModelo: Integer;
  LPorta: string;
begin
  if not ImpressaoEscPos then Exit;

  if FPosPrinter = nil then
  begin
    FPosPrinter := TACBrPosPrinter.Create(Self);
    FDANFeESCPOS := TACBrNFeDANFeESCPOS.Create(Self);
    FDANFeESCPOS.PosPrinter := FPosPrinter;
  end;

  // O ACBrDevice RECUSA trocar de porta com o device ativo (SetPorta levanta
  // excecao), e a impressora fica ativa desde a primeira impressao - nem o
  // teste nem o cupom desativam depois. Sem este Desativar, salvar uma porta
  // nova gravava o ini mas a impressora continuava na porta antiga: o teste
  // ia para o lugar velho e nao saia nada, sem erro visivel na tela.
  if FPosPrinter.Ativo then
    FPosPrinter.Desativar;

  // Modelo do INI como nome do enum (ex: ppEscPosEpson, ppEscBematech)
  LModelo := GetEnumValue(TypeInfo(TACBrPosPrinterModelo), FEscPosModelo);
  if LModelo < 0 then
    LModelo := Ord(ppEscPosEpson);
  FPosPrinter.Modelo := TACBrPosPrinterModelo(LModelo);

  // Porta: escpos_porta explicita (COM3, TCP:ip:9100, RAW:Nome...) ou, se
  // vazia, spooler RAW na impressora configurada em [impressao] impressora=
  LPorta := Trim(FEscPosPorta);
  if (LPorta = '') and (Trim(FImpressoraCupom) <> '') then
    LPorta := 'RAW:' + Trim(FImpressoraCupom);
  FPosPrinter.Porta := LPorta;
  FPosPrinter.ColunasFonteNormal := FEscPosColunas;

  // O DANFe do ACBrNFe passa a ser o ESC/POS (Imprimir vai direto na termica)
  ACBrNFe.DANFE := FDANFeESCPOS;
end;

procedure TDmApoloWeb.ConfigurarACBrNFCe(const AParams: TParametrosFilial);
begin
  // Certificado digital (arquivo extraido do BLOB Oracle)
  ACBrNFe.Configuracoes.Certificados.ArquivoPFX := ARQUIVO_CERTIFICADO;
  ACBrNFe.Configuracoes.Certificados.Senha := AParams.SenhaCertificado;
  ACBrNFe.Configuracoes.Arquivos.PathSchemas := PASTA_SCHEMAS;

  // CSC e IDCSC (da tabela msfilial)
  ACBrNFe.Configuracoes.Geral.CSC := AParams.CSC;
  ACBrNFe.Configuracoes.Geral.IdCSC := AParams.IDCSC;

  // Configuracoes gerais NFCe
  ACBrNFe.Configuracoes.Geral.ModeloDF := moNFCe;
  ACBrNFe.Configuracoes.Geral.VersaoDF := ve400;
  ACBrNFe.Configuracoes.Geral.VersaoQRCode := veqr200;
  ACBrNFe.Configuracoes.Geral.FormaEmissao := teNormal;
  ACBrNFe.Configuracoes.Geral.ValidarDigest := True;

  // Ambiente e UF (da tabela msfilial)
  // ambiente_nfe: '1' ou 'P' = producao; qualquer outro valor = homologacao
  if (AParams.AmbienteNFe = '1') or
     SameText(Copy(Trim(AParams.AmbienteNFe), 1, 1), 'P') then
    ACBrNFe.Configuracoes.WebServices.Ambiente := taProducao
  else
    ACBrNFe.Configuracoes.WebServices.Ambiente := taHomologacao;
  ACBrNFe.Configuracoes.WebServices.UF := AParams.UFWebService;

  // SSL
  ACBrNFe.Configuracoes.Geral.SSLLib := libOpenSSL;
  ACBrNFe.Configuracoes.Geral.SSLCryptLib := cryOpenSSL;
  ACBrNFe.Configuracoes.Geral.SSLHttpLib := httpOpenSSL;
  ACBrNFe.Configuracoes.Geral.SSLXmlSignLib := xsLibXml2;

  // Paths
  ACBrNFe.Configuracoes.Arquivos.Salvar := True;
  ACBrNFe.Configuracoes.Arquivos.PathSalvar := PASTA_NFCE + 'XML\';
  ACBrNFe.Configuracoes.Arquivos.SepararPorMes := True;
  ACBrNFe.Configuracoes.Arquivos.AdicionarLiteral := True;

  // DANFCe
  ACBrNFe.DANFE := ACBrNFeDANFCe;
  ACBrNFeDANFCe.PathPDF:=PASTA_NFCE+'PDF\';
  ForceDirectories(ACBrNFeDANFCe.PathPDF);

  // Logo (TACBrNFCeDANFeFPDF exige PNG)
  if FileExists(ARQUIVO_LOGO) then
    try
      ACBrNFeDANFCe.Logo := ARQUIVO_LOGO;
    except
      // Logo invalido ou formato incompativel - continuar sem logo
    end;

  // Se [impressao] modo=ESCPOS, troca o DANFE para impressao direta na termica
  ConfigurarImpressaoCupom;
end;

function TDmApoloWeb.ModelosPosPrinter: TArray<string>;
var
  LInfo: PTypeInfo;
  LData: PTypeData;
  I: Integer;
begin
  LInfo := TypeInfo(TACBrPosPrinterModelo);
  LData := GetTypeData(LInfo);
  SetLength(Result, LData.MaxValue - LData.MinValue + 1);
  for I := LData.MinValue to LData.MaxValue do
    Result[I - LData.MinValue] := GetEnumName(LInfo, I);
end;

// Rele a secao [impressao] do apoloweb.ini e reaplica no ACBr, sem reiniciar
// o caixa. Voltando para SUMATRA o DANFE precisa retornar ao gerador de PDF,
// senao o cupom continuaria saindo pelo ESC/POS da configuracao anterior.
procedure TDmApoloWeb.RecarregarConfiguracaoImpressao;
var
  ini: TIniFile;
begin
  ini := TIniFile.Create(ARQ_APOLOWEB_INI);
  try
    FModoImpressao   := UpperCase(Trim(ini.ReadString('impressao','modo','SUMATRA')));
    FImpressoraCupom := ini.ReadString('impressao','impressora','');
    FEscPosModelo    := ini.ReadString('impressao','escpos_modelo','ppEscPosEpson');
    FEscPosPorta     := ini.ReadString('impressao','escpos_porta','');
    FEscPosColunas   := ini.ReadInteger('impressao','escpos_colunas', 48);
  finally
    ini.Free;
  end;

  if ImpressaoEscPos then
    ConfigurarImpressaoCupom
  else
    ACBrNFe.DANFE := ACBrNFeDANFCe;
end;

// Reaplica no ACBr o certificado e os dados fiscais do cache SQLite. Chamado
// depois que a carga geral rebaixa o PFX que estava faltando em disco - sem
// isso o ACBr continuaria com ArquivoPFX vazio (app iniciado sem certificado).
procedure TDmApoloWeb.RecarregarConfiguracaoNFCe;
var
  LParams: TParametrosFilial;
begin
  if not FileExists(ARQUIVO_CERTIFICADO) then Exit;

  LParams := Default(TParametrosFilial);
  LParams.CodFilial := FCodFilial;
  LParams.SenhaCertificado := FSQLiteDB.ObterEstado('SENHA_CERTIFICADO', '');
  LParams.CSC := FSQLiteDB.ObterEstado('CSC', '');
  LParams.IDCSC := FSQLiteDB.ObterEstado('IDCSC', '');
  LParams.AmbienteNFe := FSQLiteDB.ObterEstado('AMBIENTE_NFE', '2');
  LParams.UFWebService := FSQLiteDB.ObterEstado('UF_WEBSERVICE', 'SP');
  ConfigurarACBrNFCe(LParams);
end;

// =========================================================================
// CONEXAO ORACLE
// =========================================================================

procedure TDmApoloWeb.ConectarOracle;
begin
  try
    if not UniConnOracle.Connected then
      UniConnOracle.Open;
    FConectadoOracle := UniConnOracle.Connected;
  except
    FConectadoOracle := False;
  end;
end;

procedure TDmApoloWeb.DesconectarOracle;
begin
  if UniConnOracle.Connected then
    UniConnOracle.Close;
  FConectadoOracle := False;
end;

function TDmApoloWeb.TestarConexaoOracle: Boolean;
begin
  try
    if not UniConnOracle.Connected then
      ConectarOracle;
    Result := UniConnOracle.Connected;
  except
    Result := False;
  end;
end;

function TDmApoloWeb.ExecutarSelectOracle(const ASQL: string): TUniQuery;
begin
  Result := TUniQuery.Create(nil);
  Result.Connection := UniConnOracle;
  Result.SQL.Text := ASQL;
  Result.Open;
end;

procedure TDmApoloWeb.ExecutarSQLOracle(const ASQL: string);
var
  LQuery: TUniQuery;
begin
  LQuery := TUniQuery.Create(nil);
  try
    LQuery.Connection := UniConnOracle;
    LQuery.SQL.Text := ASQL;
    LQuery.Execute;
  finally
    LQuery.Free;
  end;
end;

end.
