object FrmConfigConexao: TFrmConfigConexao
  Left = 0
  Top = 0
  BorderStyle = bsDialog
  Caption = 'Configuracao - ApoloWeb'
  ClientHeight = 455
  ClientWidth = 450
  Color = 3355443
  Font.Charset = DEFAULT_CHARSET
  Font.Color = clWhite
  Font.Height = -13
  Font.Name = 'Segoe UI'
  Font.Style = []
  Position = poScreenCenter
  OnCreate = FormCreate
  TextHeight = 17
  object PnlTitulo: TPanel
    Left = 0
    Top = 0
    Width = 450
    Height = 45
    Align = alTop
    BevelOuter = bvNone
    Caption = 'Configuracao - ApoloWeb'
    Color = 2236962
    Font.Charset = DEFAULT_CHARSET
    Font.Color = clWhite
    Font.Height = -16
    Font.Name = 'Segoe UI'
    Font.Style = [fsBold]
    ParentFont = False
    TabOrder = 0
  end
  object LblSecConexao: TLabel
    Left = 24
    Top = 55
    Width = 120
    Height = 17
    Caption = 'CONEXAO ORACLE'
    Font.Charset = DEFAULT_CHARSET
    Font.Color = 8421631
    Font.Height = -13
    Font.Name = 'Segoe UI'
    Font.Style = [fsBold]
    ParentFont = False
  end
  object LblServidor: TLabel
    Left = 24
    Top = 82
    Width = 52
    Height = 17
    Caption = 'Servidor:'
  end
  object EdtServidor: TEdit
    Left = 130
    Top = 79
    Width = 295
    Height = 25
    Color = 4473924
    Font.Charset = DEFAULT_CHARSET
    Font.Color = clWhite
    Font.Height = -13
    Font.Name = 'Segoe UI'
    Font.Style = []
    ParentFont = False
    TabOrder = 1
  end
  object LblPorta: TLabel
    Left = 24
    Top = 114
    Width = 34
    Height = 17
    Caption = 'Porta:'
  end
  object EdtPorta: TEdit
    Left = 130
    Top = 111
    Width = 100
    Height = 25
    Color = 4473924
    Font.Charset = DEFAULT_CHARSET
    Font.Color = clWhite
    Font.Height = -13
    Font.Name = 'Segoe UI'
    Font.Style = []
    ParentFont = False
    TabOrder = 2
    Text = '1521'
  end
  object LblUsuario: TLabel
    Left = 24
    Top = 146
    Width = 48
    Height = 17
    Caption = 'Usuario:'
  end
  object EdtUsuario: TEdit
    Left = 130
    Top = 143
    Width = 295
    Height = 25
    Color = 4473924
    Font.Charset = DEFAULT_CHARSET
    Font.Color = clWhite
    Font.Height = -13
    Font.Name = 'Segoe UI'
    Font.Style = []
    ParentFont = False
    TabOrder = 3
  end
  object LblSenhaDB: TLabel
    Left = 24
    Top = 178
    Width = 58
    Height = 17
    Caption = 'Senha BD:'
  end
  object EdtSenhaDB: TEdit
    Left = 130
    Top = 175
    Width = 295
    Height = 25
    Color = 4473924
    Font.Charset = DEFAULT_CHARSET
    Font.Color = clWhite
    Font.Height = -13
    Font.Name = 'Segoe UI'
    Font.Style = []
    ParentFont = False
    PasswordChar = '*'
    TabOrder = 4
  end
  object BtnTestar: TButton
    Left = 24
    Top = 214
    Width = 120
    Height = 30
    Caption = 'Testar Conexao'
    TabOrder = 5
    OnClick = BtnTestarClick
  end
  object LblStatus: TLabel
    Left = 160
    Top = 220
    Width = 265
    Height = 17
    AutoSize = False
    Font.Charset = DEFAULT_CHARSET
    Font.Color = clYellow
    Font.Height = -13
    Font.Name = 'Segoe UI'
    Font.Style = []
    ParentFont = False
  end
  object BevelSep1: TBevel
    Left = 24
    Top = 255
    Width = 400
    Height = 2
  end
  object LblSecNFCe: TLabel
    Left = 24
    Top = 268
    Width = 40
    Height = 17
    Caption = 'NFC-e'
    Font.Charset = DEFAULT_CHARSET
    Font.Color = 8421631
    Font.Height = -13
    Font.Name = 'Segoe UI'
    Font.Style = [fsBold]
    ParentFont = False
  end
  object LblProxNFCe: TLabel
    Left = 24
    Top = 296
    Width = 87
    Height = 17
    Caption = 'Prox. num. nNF:'
  end
  object EdtProxNFCe: TEdit
    Left = 130
    Top = 293
    Width = 120
    Height = 25
    Color = 4473924
    Font.Charset = DEFAULT_CHARSET
    Font.Color = clWhite
    Font.Height = -13
    Font.Name = 'Segoe UI'
    Font.Style = []
    ParentFont = False
    TabOrder = 6
  end
  object LblSerieNFCe: TLabel
    Left = 270
    Top = 296
    Width = 35
    Height = 17
    Caption = 'Serie:'
  end
  object EdtSerieNFCe: TEdit
    Left = 315
    Top = 293
    Width = 60
    Height = 25
    Color = 4473924
    Font.Charset = DEFAULT_CHARSET
    Font.Color = clWhite
    Font.Height = -13
    Font.Name = 'Segoe UI'
    Font.Style = []
    ParentFont = False
    TabOrder = 7
  end
  object BevelSep2: TBevel
    Left = 24
    Top = 333
    Width = 400
    Height = 2
  end
  object LblSenhaAdmin: TLabel
    Left = 24
    Top = 350
    Width = 86
    Height = 17
    Caption = 'Senha Admin:'
    Font.Charset = DEFAULT_CHARSET
    Font.Color = 8421631
    Font.Height = -13
    Font.Name = 'Segoe UI'
    Font.Style = [fsBold]
    ParentFont = False
  end
  object EdtSenhaAdmin: TEdit
    Left = 130
    Top = 347
    Width = 295
    Height = 25
    Color = 4473924
    Font.Charset = DEFAULT_CHARSET
    Font.Color = clWhite
    Font.Height = -13
    Font.Name = 'Segoe UI'
    Font.Style = []
    ParentFont = False
    PasswordChar = '*'
    TabOrder = 8
  end
  object BtnSalvar: TButton
    Left = 215
    Top = 400
    Width = 100
    Height = 33
    Caption = 'Salvar'
    TabOrder = 9
    OnClick = BtnSalvarClick
  end
  object BtnCancelar: TButton
    Left = 325
    Top = 400
    Width = 100
    Height = 33
    Caption = 'Cancelar'
    ModalResult = 2
    TabOrder = 10
  end
end
