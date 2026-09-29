# ============================================================================
#  diagnostico-cliente.ps1 - Rodar NA MAQUINA DO CLIENTE (tela branca ApoloWeb)
#  Uso: powershell -ExecutionPolicy Bypass -File diagnostico-cliente.ps1
# ============================================================================
$ErrorActionPreference = 'Continue'
Write-Host "=== Diagnostico ApoloWeb (tela branca) ===" -ForegroundColor Cyan

# 1. WebView2 Runtime (virtual host mapping exige versao 89+)
Write-Host "`n[1] WebView2 Runtime:" -ForegroundColor Yellow
$found = $false
$regPaths = @(
    'HKLM:\SOFTWARE\WOW6432Node\Microsoft\EdgeUpdate\Clients\{F3017226-FE2A-4295-8BDF-00C3A9A7E4C5}',
    'HKLM:\SOFTWARE\Microsoft\EdgeUpdate\Clients\{F3017226-FE2A-4295-8BDF-00C3A9A7E4C5}',
    'HKCU:\SOFTWARE\Microsoft\EdgeUpdate\Clients\{F3017226-FE2A-4295-8BDF-00C3A9A7E4C5}'
)
foreach ($rp in $regPaths) {
    if (Test-Path $rp) {
        $ver = (Get-ItemProperty $rp -Name 'pv' -ErrorAction SilentlyContinue).pv
        if ($ver) {
            $found = $true
            $major = [int]($ver.Split('.')[0])
            $cor = 'Green'; $obs = 'OK'
            if ($major -lt 89) { $cor = 'Red'; $obs = 'MUITO ANTIGO - nao suporta virtual host mapping! ATUALIZAR' }
            Write-Host "  $rp"
            Write-Host "  Versao: $ver  ($obs)" -ForegroundColor $cor
        }
    }
}
if (-not $found) {
    Write-Host "  NAO INSTALADO! Instalar de:" -ForegroundColor Red
    Write-Host "  https://developer.microsoft.com/en-us/microsoft-edge/webview2/"
}

# 2. Windows
Write-Host "`n[2] Windows:" -ForegroundColor Yellow
$os = Get-CimInstance Win32_OperatingSystem
Write-Host "  $($os.Caption)  build $($os.BuildNumber)"

# 3. Pasta web extraida do EXE
Write-Host "`n[3] C:\Apolo\web (extraida do EXE no boot):" -ForegroundColor Yellow
if (Test-Path 'C:\Apolo\web\index.html') {
    $files = Get-ChildItem 'C:\Apolo\web' -Recurse -File
    Write-Host "  index.html OK ($($files.Count) arquivos)" -ForegroundColor Green
    $files | ForEach-Object { "    $($_.LastWriteTime)  $($_.FullName.Substring(13))" }
} else {
    Write-Host "  index.html NAO EXISTE - extracao falhou (permissao/antivirus?)" -ForegroundColor Red
}

# 4. Permissao de escrita em C:\Apolo\web
Write-Host "`n[4] Escrita em C:\Apolo\web:" -ForegroundColor Yellow
try {
    $t = 'C:\Apolo\web\__teste_escrita.tmp'
    [IO.File]::WriteAllText($t, 'x'); Remove-Item $t -Force
    Write-Host "  OK" -ForegroundColor Green
} catch {
    Write-Host "  FALHOU: $($_.Exception.Message)" -ForegroundColor Red
}

# 5. WebView2Loader.dll
Write-Host "`n[5] WebView2Loader.dll:" -ForegroundColor Yellow
$dll = 'C:\Apolo\WebView2Loader.dll'
if (Test-Path $dll) {
    $vi = (Get-Item $dll).VersionInfo
    Write-Host "  Versao: $($vi.FileVersion)"
    if ($vi.FileVersion -like '0.9*') { Write-Host "  ATENCAO: pre-release, atualizar para 1.0.x!" -ForegroundColor Red }
} else {
    Write-Host "  NAO ENCONTRADA em C:\Apolo" -ForegroundColor Red
}

# 6. EXE - qual build esta rodando
Write-Host "`n[6] ApoloWeb.exe:" -ForegroundColor Yellow
$exe = Get-Item 'C:\Apolo\ApoloWeb.exe' -ErrorAction SilentlyContinue
if ($exe) {
    Write-Host "  Data: $($exe.LastWriteTime)  Tamanho: $([math]::Round($exe.Length/1MB,1)) MB"
} else {
    Write-Host "  NAO ENCONTRADO" -ForegroundColor Red
}

Write-Host "`n=== Fim. Envie esta tela para o suporte. ===" -ForegroundColor Cyan
