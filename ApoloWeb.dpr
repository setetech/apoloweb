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
  uContingencia in 'uContingencia.pas',
  uNFCeWeb in 'uNFCeWeb.pas',
  uMonitorConexao in 'uMonitorConexao.pas',
  uSincronizacao in 'uSincronizacao.pas',
  uFrmConfigConexao in 'uFrmConfigConexao.pas' {FrmConfigConexao},
  Winapi.WebView2 in 'Winapi.WebView2.pas',
  uTEF in 'uTEF.pas',
  uWebAssets in 'uWebAssets.pas',
  uSyncLog in 'uSyncLog.pas',
  uTEFLog in 'uTEFLog.pas',
  uUploadWorker in 'uUploadWorker.pas';

{$R *.res}
// Assets web (index.html + css\*.css + js\*.js) embutidos no .exe.
// Gere/atualize com gen-webassets.ps1 APOS editar qualquer arquivo em .\web.
{$R 'ApoloWebAssets.res'}

begin
  Application.Initialize;
  SetDllDirectory( 'c:\colosso\prod\dlls' );
  // Recria os assets web em PASTA_WEB a partir dos recursos embutidos,
  // ANTES de criar o FrmMain (que navega para https://apolo.local/index.html).
  ExtrairWebAssets;
  Application.MainFormOnTaskbar := True;
  TStyleManager.TrySetStyle('Tablet Dark');
  Application.Title := 'ApoloWeb - Frente de Caixa';
  Application.CreateForm(TDmApoloWeb, DmApoloWeb);
  Application.CreateForm(TFrmMain, FrmMain);
  Application.Run;
end.
