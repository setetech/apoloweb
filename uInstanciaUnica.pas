unit uInstanciaUnica;

{ Uma instancia do ApoloWeb por maquina.

  Dois ApoloWeb abertos usam o mesmo SQLite, e a fila de envio de cada um pega
  os mesmos cupons pendentes. O envio do XML conferia "ja existe?" e gravava em
  seguida: com os dois no mesmo segundo, o XML ia duas vezes para a
  msdoceletronico e o job MSAPOLO_GERAR_NF falhava para sempre. }

interface

/// True = este e' o unico ApoloWeb da maquina. Espera o anterior terminar por
/// alguns segundos (fechamento em andamento) e, se ele continuar aberto, avisa,
/// traz a janela dele para a frente e devolve False.
function GarantirInstanciaUnica: Boolean;

implementation

uses
  Winapi.Windows, uSyncLog;

const
  // Global\ vale para outra sessao do Windows (area de trabalho remota)
  NOME_MUTEX = 'Global\ColossoApoloWebPDV';
  ESPERA_MS = 10000;

var
  GMutex: THandle = 0;

function GarantirInstanciaUnica: Boolean;
var
  LJanela: HWND;
  LEspera: DWORD;
begin
  GMutex := CreateMutex(nil, False, NOME_MUTEX);
  if GMutex = 0 then
  begin
    // Aberto por outro usuario do Windows (sem acesso ao mutex dele) = em uso.
    // Qualquer outro erro nao pode impedir o caixa de abrir.
    Result := GetLastError <> ERROR_ACCESS_DENIED;
  end
  else
  begin
    LEspera := WaitForSingleObject(GMutex, ESPERA_MS);
    // WAIT_ABANDONED: o anterior morreu sem soltar; o dono agora e' este
    Result := LEspera <> WAIT_TIMEOUT;
  end;

  if Result then
    Exit;

  SyncLog('INSTANCIA: ja existe um ApoloWeb aberto nesta maquina; esta copia foi encerrada');
  LJanela := FindWindow('TFrmMain', nil);
  if LJanela <> 0 then
  begin
    if IsIconic(LJanela) then
      ShowWindow(LJanela, SW_RESTORE);
    SetForegroundWindow(LJanela);
  end;
  MessageBox(0, 'O ApoloWeb j'#225' est'#225' aberto neste computador.',
    'ApoloWeb - Frente de Caixa', MB_OK or MB_ICONWARNING or MB_SETFOREGROUND);
end;

initialization

finalization
  // O handle fica aberto ate o fim do processo de proposito
  if GMutex <> 0 then
    CloseHandle(GMutex);

end.
