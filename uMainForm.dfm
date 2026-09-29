object FrmMain: TFrmMain
  Left = 0
  Top = 0
  Caption = #39
  ClientHeight = 768
  ClientWidth = 1366
  Color = 1511695
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
    UserDataFolder = 'C:\Apolo\WebView2Cache'
    OnCreateWebViewCompleted = EdgeBrowserCreateWebViewCompleted
    OnNavigationCompleted = EdgeBrowserNavigationCompleted
    OnWebMessageReceived = EdgeBrowserWebMessageReceived
    ExplicitLeft = 24
    ExplicitTop = 8
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
