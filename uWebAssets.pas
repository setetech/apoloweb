unit uWebAssets;

{ ============================================================================
  Extrai os assets web (index.html + css\*.css + js\*.js) que estao EMBUTIDOS
  no ApoloWeb.exe como recursos RCDATA (ver ApoloWebAssets.res /
  gen-webassets.ps1).

  O frontend continua sendo servido pelo virtual host do WebView2
  (https://apolo.local/ -> PASTA_WEB). Este unit apenas recria os arquivos em
  PASTA_WEB a partir dos recursos embutidos, ANTES da navegacao. Assim:
    - o .exe fica autocontido (nao precisa distribuir a pasta web separada);
    - a navegacao e as referencias relativas (css/js) seguem iguais.

  A extracao sobrescreve os arquivos a cada start (sempre publica a versao
  embutida no .exe).
  ============================================================================ }

interface

/// Recria todos os assets embutidos em PASTA_WEB. Seguro chamar no start
/// (antes de criar o FrmMain). Em caso de ausencia de recursos, nao faz nada.
procedure ExtrairWebAssets;

implementation

uses
  Winapi.Windows, System.SysUtils, System.IOUtils, System.Classes,
  uConstantesWeb;

function LoadResBytes(const AResName: string): TBytes;
var
  HRes: HRSRC;
  HGlob: HGLOBAL;
  P: Pointer;
  Sz: DWORD;
begin
  Result := nil;
  HRes := FindResource(HInstance, PChar(AResName), RT_RCDATA);
  if HRes = 0 then Exit;
  Sz := SizeofResource(HInstance, HRes);
  if Sz = 0 then Exit;
  HGlob := LoadResource(HInstance, HRes);
  if HGlob = 0 then Exit;
  P := LockResource(HGlob);
  if P = nil then Exit;
  SetLength(Result, Sz);
  Move(P^, Result[0], Sz);
end;

procedure ExtrairWebAssets;
var
  Manifest: TBytes;
  Lines: TArray<string>;
  Line, ResName, RelPath, Dest: string;
  Eq: Integer;
  Data: TBytes;
begin
  Manifest := LoadResBytes('WEBMANIFEST');
  if Length(Manifest) = 0 then
    Exit; // nada embutido: mantem o comportamento antigo (pasta em disco)

  Lines := TEncoding.UTF8.GetString(Manifest).Replace(#13, '').Split([#10]);
  for Line in Lines do
  begin
    if Line.Trim = '' then Continue;
    Eq := Line.IndexOf('=');
    if Eq < 0 then Continue;

    ResName := Line.Substring(0, Eq).Trim;
    RelPath := Line.Substring(Eq + 1).Trim
                 .Replace('/', PathDelim).Replace('\', PathDelim);
    Dest := TPath.Combine(PASTA_WEB, RelPath);

    Data := LoadResBytes(ResName);
    try
      ForceDirectories(TPath.GetDirectoryName(Dest));
      TFile.WriteAllBytes(Dest, Data);
    except
      on E: Exception do
        // Nao derrubar o boot: se o arquivo em disco ja existir (versao
        // anterior), o app ainda sobe com ele. Apenas avisar o operador.
        MessageBox(0, PChar('Falha ao extrair asset web: ' + Dest + sLineBreak +
          E.Message + sLineBreak + sLineBreak +
          'Verifique permissao de escrita/antivirus em ' + PASTA_WEB),
          'ApoloWeb', MB_ICONWARNING);
    end;
  end;
end;

end.
