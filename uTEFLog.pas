unit uTEFLog;

{ ============================================================================
  Log do TEF em arquivo texto, para diagnostico dos dois modos (http/arquivo).

  Arquivo: C:\Apolo\logs\tef-AAAAMMDD.log  (um por dia)
  Formato: 2026-08-24 14:35:02.123  mensagem

  Ligado/desligado por [TEF] debug no apoloweb.ini.
  Nunca lanca excecao (log nao pode derrubar a venda).
  ============================================================================ }

interface

procedure TEFLog(const AMsg: string); overload;
procedure TEFLog(const AFmt: string; const AArgs: array of const); overload;

implementation

uses
  System.SysUtils, System.IOUtils, System.SyncObjs;

var
  GLock: TCriticalSection;

procedure TEFLog(const AMsg: string);
var
  LDir, LPath: string;
begin
  try
    LDir := 'C:\Apolo\logs\';
    LPath := LDir + 'tef-' + FormatDateTime('yyyymmdd', Now) + '.log';
    GLock.Enter;
    try
      if not TDirectory.Exists(LDir) then
        TDirectory.CreateDirectory(LDir);
      TFile.AppendAllText(LPath,
        FormatDateTime('yyyy-mm-dd hh:nn:ss.zzz', Now) + '  ' + AMsg + sLineBreak,
        TEncoding.UTF8);
    finally
      GLock.Leave;
    end;
  except
    // silencioso
  end;
end;

procedure TEFLog(const AFmt: string; const AArgs: array of const);
begin
  try
    TEFLog(Format(AFmt, AArgs));
  except
  end;
end;

initialization
  GLock := TCriticalSection.Create;

finalization
  GLock.Free;

end.
