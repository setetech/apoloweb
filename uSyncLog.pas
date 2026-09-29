unit uSyncLog;

{ ============================================================================
  Log de sincronizacao em arquivo texto, para diagnostico de performance.

  Arquivo: C:\Apolo\logs\sync-AAAAMMDD.log  (um por dia)
  Formato: 2026-07-28 14:35:02.123  mensagem

  Nunca lanca excecao (log nao pode derrubar a sincronizacao nem o app).
  ============================================================================ }

interface

procedure SyncLog(const AMsg: string); overload;
procedure SyncLog(const AFmt: string; const AArgs: array of const); overload;

implementation

uses
  System.SysUtils, System.IOUtils, System.SyncObjs;

var
  GLock: TCriticalSection;

procedure SyncLog(const AMsg: string);
var
  LDir, LPath: string;
begin
  try
    LDir := 'C:\Apolo\logs\';
    LPath := LDir + 'sync-' + FormatDateTime('yyyymmdd', Now) + '.log';
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

procedure SyncLog(const AFmt: string; const AArgs: array of const);
begin
  try
    SyncLog(Format(AFmt, AArgs));
  except
  end;
end;

initialization
  GLock := TCriticalSection.Create;

finalization
  GLock.Free;

end.
