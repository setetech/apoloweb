object FrmMain: TFrmMain
  Left = 0
  Top = 0
  Caption = 'ApoloWeb - Frente de Caixa'
  ClientHeight = 768
  ClientWidth = 1366
  Color = clBlack
  Font.Charset = DEFAULT_CHARSET
  Font.Color = clWhite
  Font.Height = -13
  Font.Name = 'Segoe UI'
  Font.Style = []
  KeyPreview = True
  Position = poScreenCenter
  WindowState = wsMaximized
  OnCreate = FormCreate
  OnDestroy = FormDestroy
  OnKeyDown = FormKeyDown
  TextHeight = 17
  object EdgeBrowser: TEdgeBrowser
    Left = 0
    Top = 0
    Width = 1366
    Height = 768
    Align = alClient
    TabOrder = 0
    AllowSingleSignOnUsingOSPrimaryAccount = False
    TargetCompatibleBrowserVersion = '117.0.2045.28'
    UserDataFolder = 'C:\Apolo\WebView2Cache'
    OnCreateWebViewCompleted = EdgeBrowserCreateWebViewCompleted
    OnNavigationCompleted = EdgeBrowserNavigationCompleted
    OnWebMessageReceived = EdgeBrowserWebMessageReceived
  end
  object TimerInit: TTimer
    Enabled = False
    Interval = 200
    OnTimer = TimerInitTimer
    Left = 48
    Top = 48
  end
  object TimerDiag: TTimer
    Enabled = False
    Interval = 3000
    OnTimer = TimerDiagTimer
    Left = 120
    Top = 48
  end
end
