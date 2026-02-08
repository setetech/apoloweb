# WebView2 + TEdgeBrowser (Delphi) - Guia de Troubleshooting

## Visao Geral da Arquitetura

```
  Sua Aplicacao Delphi (.exe)
         |
         v
  TEdgeBrowser (Vcl.Edge)           <-- Componente VCL
         |
         v
  WebView2Loader.dll                <-- DLL no diretorio do EXE
         |                              Funcao: localizar o Runtime via registro
         v
  WebView2 Runtime (Edge Chromium)  <-- Instalado no Windows
         |                              Local: gerenciado pelo EdgeUpdate
         v
  Renderizacao HTML/CSS/JS          <-- Seu frontend
```

### Componentes Envolvidos

| Componente | O que e | Onde vive |
|---|---|---|
| **TEdgeBrowser** | Componente Delphi VCL que encapsula o WebView2 | Compilado no EXE (unit Vcl.Edge) |
| **WebView2Loader.dll** | DLL redistribuivel que localiza e carrega o Runtime | Diretorio do EXE |
| **WebView2 Runtime** | Motor Chromium (Edge) que renderiza HTML | Instalado no Windows (via EdgeUpdate) |
| **Winapi.WebView2.pas** | Interfaces COM (ICoreWebView2, ICoreWebView2_3, etc.) | Source do Delphi |

---

## Problema 1: WebView2 Nao Inicializa (BrowserControlState = 0)

### Sintoma
- Tela preta/branca, nenhum conteudo
- `BrowserControlState = 0` (None) - nunca sai do estado inicial
- Evento `OnCreateWebViewCompleted` nunca dispara
- Nenhuma mensagem de erro visivel

### Causa Raiz
**WebView2Loader.dll versao incorreta.** A DLL v0.9.x (pre-release, anterior a Jan/2021)
nao e compativel com o Runtime WebView2 atual (v100+) nem com o TEdgeBrowser do Delphi 11+.

O TEdgeBrowser tenta carregar a DLL internamente durante `CreateWebView`, mas se a versao
da DLL for muito antiga, a chamada falha silenciosamente e o `BrowserControlState` permanece
em 0 (None).

### Como Diagnosticar

1. **Verificar versao da DLL:**
   ```
   Botao direito no WebView2Loader.dll > Propriedades > Detalhes > Versao do Arquivo
   ```
   - v0.9.x = **INCOMPATIVEL** (pre-release)
   - v1.0.x = **OK** (GA/release)

2. **Verificar arquitetura (32 vs 64 bit):**
   A DLL deve corresponder ao target da aplicacao:
   - Aplicacao Win32 → WebView2Loader.dll 32-bit (x86)
   - Aplicacao Win64 → WebView2Loader.dll 64-bit (x64)

3. **Verificar Runtime instalado:**
   No registro do Windows:
   ```
   HKLM\SOFTWARE\WOW6432Node\Microsoft\EdgeUpdate\Clients\{F3017226-FE2A-4295-8BDF-00C3A9A7E4C5}
   ```
   Valor `pv` = versao do Runtime (ex: 144.0.3719.115)

### Como Resolver

**Obter a DLL correta do NuGet:**

```powershell
# Baixar o pacote NuGet do WebView2 SDK
Invoke-WebRequest -Uri 'https://www.nuget.org/api/v2/package/Microsoft.Web.WebView2' -OutFile webview2sdk.zip

# Extrair
Expand-Archive webview2sdk.zip -DestinationPath webview2sdk

# Copiar a DLL 32-bit para o diretorio do EXE
Copy-Item 'webview2sdk\build\native\x86\WebView2Loader.dll' 'C:\SeuApp\'

# Ou 64-bit:
Copy-Item 'webview2sdk\build\native\x64\WebView2Loader.dll' 'C:\SeuApp\'

# Limpar
Remove-Item webview2sdk.zip
Remove-Item webview2sdk -Recurse
```

**Verificar apos a copia:**
- Versao deve ser 1.0.x (ex: 1.0.3719.77)
- Arquitetura deve corresponder ao EXE

---

## Problema 2: TEdgeBrowser Nao Dispara Inicializacao Automaticamente

### Sintoma
- DLL correta, Runtime instalado
- `BrowserControlState` permanece em 0
- `HandleAllocated = True`, `Visible = True`, `Parent <> nil`
- Tudo parece OK mas o WebView nunca inicializa

### Causa Raiz
**TEdgeBrowser NAO inicializa automaticamente no `CreateWnd`.**

Diferente do que muitos esperam, o metodo `CreateWnd` do TCustomEdgeBrowser so
reinicializa se `FWebView <> nil` (ou seja, se ja foi inicializado antes):

```pascal
// Vcl.Edge.pas - Delphi 11 (Studio 23.0)
procedure TCustomEdgeBrowser.CreateWnd;
begin
  inherited;
  if FWebView <> nil then     // <-- So reinicializa se ja existia!
  begin
    FLastURI := LocationURL;
    ReinitializeWebView;
  end;
end;
```

A inicializacao REAL e disparada pelo metodo `Navigate`:

```pascal
function TCustomEdgeBrowser.Navigate(const AUri: string): Boolean;
begin
  Result := False;
  if FWebView = nil then
  begin
    if BrowserControlState = TBrowserControlState.None then
      CreateWebView;           // <-- AQUI inicia de verdade!
    if AUri.Trim.Length > 0 then
      FLastURI := AUri;        // <-- Salva URL para auto-navegar depois
  end
  else
    Result := ProcessHResult(FWebView.Navigate(PChar(AUri)));
end;
```

### Como Resolver

**Chamar `Navigate` no FormCreate ou apos configurar o EdgeBrowser:**

```pascal
procedure TFrmMain.ConfigurarEdgeBrowser;
begin
  EdgeBrowser.Align := alClient;
  EdgeBrowser.UserDataFolder := 'C:\SeuApp\WebView2Cache';

  // OBRIGATORIO: Navigate dispara CreateWebView internamente
  EdgeBrowser.Navigate('https://seuhost.local/index.html');
end;
```

### IMPORTANTE: Sequencia de Eventos

```
Navigate('URL')
  |
  +-- FWebView = nil? Sim → CreateWebView() + FLastURI = 'URL'
  |
  v
[Async] Cria ambiente WebView2...
  |
  v
OnCreateWebViewCompleted dispara
  |  (seu codigo: configurar settings, virtual host, etc.)
  |
  v
[Interno] TEdgeBrowser auto-navega para FLastURI
  |
  v
OnNavigationCompleted dispara
   (seu codigo: inicializar sistema)
```

**NAO chame Navigate dentro de OnCreateWebViewCompleted!**
O TEdgeBrowser auto-navega para `FLastURI` APOS `OnCreateWebViewCompleted` retornar.
Se voce chamar Navigate de novo dentro do evento, a navegacao interna sobrescreve a sua.

---

## Problema 3: HTML Carrega Mas CSS/JS Nao (Tela Branca)

### Sintoma
- WebView2 inicializa OK (`OnCreateWebViewCompleted` com sucesso)
- Navegacao completa OK (`OnNavigationCompleted` com IsSuccess=True)
- Pagina aparece branca (sem estilos CSS)
- DevTools mostra erros de carregamento de recursos

### Causa Raiz
**O protocolo `file:///` tem restricoes de seguranca** que podem impedir o carregamento
de recursos relativos (CSS, JS, imagens) em certas configuracoes do WebView2.

URL como `file:///C:/Apolo/web/index.html` pode falhar ao carregar
`<link href="css/main.css">` devido a politicas de seguranca de origem cruzada.

### Como Resolver

**Usar `SetVirtualHostNameToFolderMapping` (recomendado):**

Essa funcao mapeia um hostname virtual para uma pasta local, simulando um servidor web:

```pascal
procedure TFrmMain.EdgeBrowserCreateWebViewCompleted(
  Sender: TCustomEdgeBrowser; AResult: HRESULT);
var
  LWebView3: ICoreWebView2_3;
begin
  if Succeeded(AResult) then
  begin
    // Mapear hostname virtual para pasta local
    if Succeeded(EdgeBrowser.DefaultInterface.QueryInterface(
         ICoreWebView2_3, LWebView3)) then
    begin
      LWebView3.SetVirtualHostNameToFolderMapping(
        'meuapp.local',                                    // hostname virtual
        PChar('C:\SeuApp\web\'),                           // pasta fisica
        COREWEBVIEW2_HOST_RESOURCE_ACCESS_KIND_ALLOW        // permitir acesso
      );
    end;
  end;
end;
```

**No Navigate, usar o hostname virtual:**
```pascal
EdgeBrowser.Navigate('https://meuapp.local/index.html');
```

**Resultado:** Todos os caminhos relativos no HTML funcionam normalmente:
```html
<link rel="stylesheet" href="css/main.css">   <!-- OK! -->
<script src="js/app.js"></script>              <!-- OK! -->
<img src="images/logo.png">                    <!-- OK! -->
```

### Requisitos
- Interface `ICoreWebView2_3` (disponivel no Delphi 11+, unit `Winapi.WebView2`)
- Constante `COREWEBVIEW2_HOST_RESOURCE_ACCESS_KIND_ALLOW = $00000001`

---

## Checklist Completo Para Novo Projeto

### Prerequisitos no PC do Usuario

- [ ] **WebView2 Runtime instalado**
  - Windows 10/11 recente ja inclui (via Edge)
  - Verificar: `HKLM\SOFTWARE\...\EdgeUpdate\Clients\{F3017226-...}`
  - Download: https://developer.microsoft.com/en-us/microsoft-edge/webview2/

- [ ] **WebView2Loader.dll v1.0.x+ (32-bit ou 64-bit conforme o EXE)**
  - Obter via NuGet: `Microsoft.Web.WebView2`
  - Colocar NO MESMO diretorio do EXE
  - **NUNCA usar v0.9.x** (pre-release, incompativel)

### Configuracao no Delphi

- [ ] **DFM do Form:**
  ```
  object EdgeBrowser: TEdgeBrowser
    Align = alClient
    UserDataFolder = 'C:\SeuApp\WebView2Cache'
    OnCreateWebViewCompleted = EdgeBrowserCreateWebViewCompleted
    OnNavigationCompleted = EdgeBrowserNavigationCompleted
    OnWebMessageReceived = EdgeBrowserWebMessageReceived
  end
  ```

- [ ] **Uses clause:**
  ```pascal
  uses Vcl.Edge, Winapi.WebView2, ActiveX;
  ```
  > Usar `Winapi.WebView2` (nao `WebView2`) para ter acesso a `ICoreWebView2_3`

- [ ] **Inicializacao (FormCreate):**
  ```pascal
  ForceDirectories('C:\SeuApp\WebView2Cache');
  EdgeBrowser.UserDataFolder := 'C:\SeuApp\WebView2Cache';
  EdgeBrowser.Navigate('https://meuapp.local/index.html');
  ```

- [ ] **OnCreateWebViewCompleted:**
  ```pascal
  // 1. Configurar virtual host mapping
  // 2. Configurar settings (DevTools, ContextMenu, etc.)
  // 3. NAO chamar Navigate aqui
  ```

- [ ] **OnNavigationCompleted:**
  ```pascal
  // Ignorar about:blank
  // Inicializar sistema quando frontend carregar
  ```

### Estrutura de Pastas

```
C:\SeuApp\
  +-- SeuApp.exe
  +-- WebView2Loader.dll          <-- v1.0.x, mesma arquitetura do EXE
  +-- WebView2Cache\              <-- UserDataFolder (criado automaticamente)
  +-- web\                        <-- Seus arquivos frontend
       +-- index.html
       +-- css\
       +-- js\
       +-- images\
```

---

## Tabela Resumo de Erros

| BrowserControlState | Significado | Causa Provavel | Solucao |
|---|---|---|---|
| **0 (None)** | Nunca tentou inicializar | DLL incompativel OU falta Navigate() | Atualizar DLL + chamar Navigate |
| **1 (Creating)** | Inicializando... | Normal, aguardar | Esperar OnCreateWebViewCompleted |
| **2 (Created)** | OK, funcionando | - | - |
| **3 (Failed)** | Falhou ao criar | HRESULT no evento | Ver codigo HRESULT |

| HRESULT | Significado | Solucao |
|---|---|---|
| **80004002** | E_NOINTERFACE | DLL/Runtime incompativeis, atualizar DLL |
| **80070002** | FILE_NOT_FOUND | WebView2Loader.dll nao encontrada |
| **80004005** | E_FAIL | UserDataFolder sem permissao de escrita |
| **80070005** | E_ACCESSDENIED | Pasta bloqueada por antivirus/permissao |

---

## Script PowerShell de Diagnostico

Salve como `diagnostico-webview2.ps1` e execute no PC do usuario:

```powershell
Write-Host "=== Diagnostico WebView2 ===" -ForegroundColor Cyan

# 1. Verificar Runtime
Write-Host "`n[1] WebView2 Runtime:" -ForegroundColor Yellow
$regPath = 'HKLM:\SOFTWARE\WOW6432Node\Microsoft\EdgeUpdate\Clients\{F3017226-FE2A-4295-8BDF-00C3A9A7E4C5}'
if (Test-Path $regPath) {
    $ver = (Get-ItemProperty $regPath -Name 'pv' -ErrorAction SilentlyContinue).pv
    Write-Host "  Instalado: v$ver" -ForegroundColor Green
} else {
    Write-Host "  NAO INSTALADO!" -ForegroundColor Red
    Write-Host "  Baixe em: https://developer.microsoft.com/en-us/microsoft-edge/webview2/"
}

# 2. Verificar DLL
Write-Host "`n[2] WebView2Loader.dll:" -ForegroundColor Yellow
$exeDir = 'C:\Apolo\'  # <-- Alterar para o diretorio do seu EXE
$dllPath = Join-Path $exeDir 'WebView2Loader.dll'
if (Test-Path $dllPath) {
    $vi = (Get-Item $dllPath).VersionInfo
    $bytes = [System.IO.File]::ReadAllBytes($dllPath)
    $off = [System.BitConverter]::ToInt32($bytes, 60)
    $m = [System.BitConverter]::ToUInt16($bytes, $off + 4)
    $arch = if ($m -eq 0x14c) { '32-bit' } elseif ($m -eq 0x8664) { '64-bit' } else { 'Desconhecida' }

    Write-Host "  Versao: $($vi.FileVersion)"
    Write-Host "  Arquitetura: $arch"

    if ($vi.FileVersion -like '0.9*') {
        Write-Host "  ATENCAO: Versao pre-release! Atualize para 1.0.x+" -ForegroundColor Red
    } else {
        Write-Host "  Versao OK" -ForegroundColor Green
    }
} else {
    Write-Host "  NAO ENCONTRADA em $dllPath" -ForegroundColor Red
}

# 3. Verificar EXE
Write-Host "`n[3] Aplicacao:" -ForegroundColor Yellow
$exePath = Join-Path $exeDir 'ApoloWeb.exe'  # <-- Alterar nome do EXE
if (Test-Path $exePath) {
    $bytes = [System.IO.File]::ReadAllBytes($exePath)
    $off = [System.BitConverter]::ToInt32($bytes, 60)
    $m = [System.BitConverter]::ToUInt16($bytes, $off + 4)
    $arch = if ($m -eq 0x14c) { '32-bit' } elseif ($m -eq 0x8664) { '64-bit' } else { 'Desconhecida' }
    Write-Host "  Arquitetura: $arch"
} else {
    Write-Host "  NAO ENCONTRADO em $exePath" -ForegroundColor Red
}

# 4. Verificar pasta web
Write-Host "`n[4] Arquivos Web:" -ForegroundColor Yellow
$webDir = Join-Path $exeDir 'web'
if (Test-Path (Join-Path $webDir 'index.html')) {
    $count = (Get-ChildItem $webDir -Recurse -File).Count
    Write-Host "  index.html encontrado ($count arquivos total)" -ForegroundColor Green
} else {
    Write-Host "  index.html NAO ENCONTRADO em $webDir" -ForegroundColor Red
}

# 5. Verificar UserDataFolder
Write-Host "`n[5] WebView2Cache:" -ForegroundColor Yellow
$cacheDir = Join-Path $exeDir 'WebView2Cache'
if (Test-Path $cacheDir) {
    Write-Host "  Pasta existe" -ForegroundColor Green
} else {
    Write-Host "  Pasta nao existe (sera criada automaticamente)" -ForegroundColor Yellow
}

Write-Host "`n=== Fim do Diagnostico ===" -ForegroundColor Cyan
```
