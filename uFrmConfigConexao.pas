unit uFrmConfigConexao;

interface

uses
  Winapi.Windows, System.SysUtils, System.Classes, Vcl.Graphics, Vcl.Controls,
  Vcl.Forms, Vcl.Dialogs, Vcl.StdCtrls, Vcl.ExtCtrls, System.Win.Registry,
  Uni, OracleUniProvider, System.UITypes, uConstantesWeb;

type
  TFrmConfigConexao = class(TForm)
    PnlTitulo: TPanel;
    LblSecConexao: TLabel;
    LblServidor: TLabel;
    EdtServidor: TEdit;
    LblPorta: TLabel;
    EdtPorta: TEdit;
    LblUsuario: TLabel;
    EdtUsuario: TEdit;
    LblSenhaDB: TLabel;
    EdtSenhaDB: TEdit;
    BtnTestar: TButton;
    LblStatus: TLabel;
    BevelSep1: TBevel;
    LblSecNFCe: TLabel;
    LblProxNFCe: TLabel;
    EdtProxNFCe: TEdit;
    LblSerieNFCe: TLabel;
    EdtSerieNFCe: TEdit;
    BevelSep2: TBevel;
    LblSenhaAdmin: TLabel;
    EdtSenhaAdmin: TEdit;
    BtnSalvar: TButton;
    BtnCancelar: TButton;
    procedure FormCreate(Sender: TObject);
    procedure BtnTestarClick(Sender: TObject);
    procedure BtnSalvarClick(Sender: TObject);
  private
    procedure CarregarDoRegistry;
    procedure SalvarNoRegistry;
    procedure CarregarNFCeDoSQLite;
    procedure SalvarNFCeNoSQLite;
    function TestarConexao: Boolean;
    function ValidarSenhaAdmin: Boolean;
  end;

  // Funcao publica: abre o form de config (senha validada no Salvar)
  function AbrirConfigConexao: Boolean;

implementation

{$R *.dfm}

uses
  uDmApoloWeb;

// =========================================================================
// FUNCAO PUBLICA - ABRE CONFIG DIRETO
// =========================================================================

function AbrirConfigConexao: Boolean;
var
  LForm: TFrmConfigConexao;
begin
  LForm := TFrmConfigConexao.Create(Application);
  try
    Result := (LForm.ShowModal = mrOk);
  finally
    LForm.Free;
  end;
end;

// =========================================================================
// FORM EVENTS
// =========================================================================

procedure TFrmConfigConexao.FormCreate(Sender: TObject);
begin
  CarregarDoRegistry;
  CarregarNFCeDoSQLite;
  EdtSenhaAdmin.Clear;
end;

procedure TFrmConfigConexao.BtnTestarClick(Sender: TObject);
begin
  LblStatus.Font.Color := clYellow;
  LblStatus.Caption := 'Testando conexao...';
  Application.ProcessMessages;

  if TestarConexao then
  begin
    LblStatus.Font.Color := clLime;
    LblStatus.Caption := 'Conexao OK!';
  end
  else
  begin
    LblStatus.Font.Color := clRed;
    if LblStatus.Caption = 'Testando conexao...' then
      LblStatus.Caption := 'Falha na conexao.';
  end;
end;

procedure TFrmConfigConexao.BtnSalvarClick(Sender: TObject);
begin
  // Validar campos obrigatorios
  if Trim(EdtServidor.Text) = '' then
  begin
    MessageDlg('Informe o servidor.', mtWarning, [mbOK], 0);
    EdtServidor.SetFocus;
    Exit;
  end;

  if Trim(EdtUsuario.Text) = '' then
  begin
    MessageDlg('Informe o usuario.', mtWarning, [mbOK], 0);
    EdtUsuario.SetFocus;
    Exit;
  end;

  if StrToIntDef(Trim(EdtProxNFCe.Text), 0) <= 0 then
  begin
    MessageDlg('Informe um numero valido para a proxima NFC-e.', mtWarning, [mbOK], 0);
    EdtProxNFCe.SetFocus;
    Exit;
  end;

  // Validar senha do administrador (obrigatoria para salvar)
  if not ValidarSenhaAdmin then
  begin
    MessageDlg('Senha de administrador incorreta.', mtError, [mbOK], 0);
    EdtSenhaAdmin.Clear;
    EdtSenhaAdmin.SetFocus;
    Exit;
  end;

  SalvarNoRegistry;
  SalvarNFCeNoSQLite;
  ModalResult := mrOk;
end;

// =========================================================================
// VALIDACAO SENHA ADMIN
// =========================================================================

function TFrmConfigConexao.ValidarSenhaAdmin: Boolean;
var
  LSenhaCorreta: string;
begin
  // Senha = "br" + ddmmyy (data atual)
  LSenhaCorreta := 'br' + FormatDateTime('ddmmyy', Date);
  Result := (EdtSenhaAdmin.Text = LSenhaCorreta);
end;

// =========================================================================
// REGISTRY (conexao Oracle)
// =========================================================================

procedure TFrmConfigConexao.CarregarDoRegistry;
var
  LReg: TRegistry;
begin
  LReg := TRegistry.Create;
  try
    LReg.RootKey := HKEY_CURRENT_USER;
    if LReg.OpenKey(REG_SEC_WSORA, False) then
    begin
      if LReg.ValueExists('servidor') then
        EdtServidor.Text := LReg.ReadString('servidor');
      if LReg.ValueExists('Porta') then
        EdtPorta.Text := IntToStr(LReg.ReadInteger('Porta'));
      if LReg.ValueExists('usuario') then
        EdtUsuario.Text := LReg.ReadString('usuario');
      if LReg.ValueExists('senha') then
        EdtSenhaDB.Text := LReg.ReadString('senha');
      LReg.CloseKey;
    end;
  finally
    LReg.Free;
  end;
end;

procedure TFrmConfigConexao.SalvarNoRegistry;
var
  LReg: TRegistry;
begin
  LReg := TRegistry.Create;
  try
    LReg.RootKey := HKEY_CURRENT_USER;
    if LReg.OpenKey(REG_SEC_WSORA, True) then
    begin
      LReg.WriteString('servidor', Trim(EdtServidor.Text));
      LReg.WriteInteger('Porta', StrToIntDef(EdtPorta.Text, 1521));
      LReg.WriteString('usuario', Trim(EdtUsuario.Text));
      LReg.WriteString('senha', EdtSenhaDB.Text);
      LReg.CloseKey;
    end;
  finally
    LReg.Free;
  end;
end;

// =========================================================================
// SQLITE (NFC-e)
// =========================================================================

procedure TFrmConfigConexao.CarregarNFCeDoSQLite;
begin
  if Assigned(DmApoloWeb) and Assigned(DmApoloWeb.SQLiteDB) then
  begin
    EdtProxNFCe.Text := DmApoloWeb.SQLiteDB.ObterEstado(KEY_PROX_NUM_NOTA, '1');
    EdtSerieNFCe.Text := DmApoloWeb.SQLiteDB.ObterEstado(KEY_SERIE_NFCE, '1');
  end
  else
  begin
    EdtProxNFCe.Text := '1';
    EdtSerieNFCe.Text := '1';
  end;
end;

procedure TFrmConfigConexao.SalvarNFCeNoSQLite;
begin
  if Assigned(DmApoloWeb) and Assigned(DmApoloWeb.SQLiteDB) then
  begin
    DmApoloWeb.SQLiteDB.SalvarEstado(KEY_PROX_NUM_NOTA,
      IntToStr(StrToIntDef(Trim(EdtProxNFCe.Text), 1)));
    DmApoloWeb.SQLiteDB.SalvarEstado(KEY_SERIE_NFCE,
      IntToStr(StrToIntDef(Trim(EdtSerieNFCe.Text), 1)));
  end;
end;

// =========================================================================
// TESTE DE CONEXAO
// =========================================================================

function TFrmConfigConexao.TestarConexao: Boolean;
var
  LConn: TUniConnection;
begin
  Result := False;
  LConn := TUniConnection.Create(nil);
  try
    LConn.ProviderName := 'Oracle';
    LConn.Server := Trim(EdtServidor.Text);
    LConn.Port := StrToIntDef(EdtPorta.Text, 1521);
    LConn.Username := Trim(EdtUsuario.Text);
    LConn.Password := EdtSenhaDB.Text;
    LConn.LoginPrompt := False;
    LConn.SpecificOptions.Values['Direct'] := 'True';
    try
      LConn.Open;
      Result := LConn.Connected;
      if Result then
        LConn.Close;
    except
      on E: Exception do
      begin
        LblStatus.Font.Color := clRed;
        LblStatus.Caption := Copy(E.Message, 1, 80);
      end;
    end;
  finally
    LConn.Free;
  end;
end;

end.
