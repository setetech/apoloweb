program ApoloWeb;

uses
  Vcl.Forms,
  Vcl.Themes,
  Vcl.Styles,
  WinApi.Windows,
  uMainForm in 'uMainForm.pas' {FrmMain},
  uDmApoloWeb in 'uDmApoloWeb.pas' {DmApoloWeb: TDataModule},
  uBridge in 'uBridge.pas',
  uSQLiteDB in 'uSQLiteDB.pas',
  uConstantesWeb in 'uConstantesWeb.pas',
  uTypesApoloWeb in 'uTypesApoloWeb.pas',
  uConexaoWeb in 'uConexaoWeb.pas',
  uContingencia in 'uContingencia.pas',
  uNFCeWeb in 'uNFCeWeb.pas',
  uMonitorConexao in 'uMonitorConexao.pas',
  uSincronizacao in 'uSincronizacao.pas',
  uFrmConfigConexao in 'uFrmConfigConexao.pas' {FrmConfigConexao};

{$R *.res}

begin
  Application.Initialize;
  SetDllDirectory( 'c:\colosso\prod\dlls' );
  Application.MainFormOnTaskbar := True;
  TStyleManager.TrySetStyle('Tablet Dark');
  Application.Title := 'ApoloWeb - Frente de Caixa';
  Application.CreateForm(TDmApoloWeb, DmApoloWeb);
  Application.CreateForm(TFrmMain, FrmMain);

  Application.Run;
end.
