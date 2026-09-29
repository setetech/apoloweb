# ============================================================================
#  gen-webassets.ps1  -  Embute os assets web (HTML/CSS/JS) no ApoloWeb.exe.
#
#  Varre a pasta .\web por *.html, *.css e *.js (recursivo) e gera:
#     ApoloWebAssets.rc        (um RCDATA por arquivo + o manifesto)
#     ApoloWebAssets.manifest  (mapeia NomeDoRecurso = caminho relativo a web\)
#     ApoloWebAssets.res       (compilado com brcc32)
#
#  O .res e' linkado no .exe por  {$R 'ApoloWebAssets.res'}  no ApoloWeb.dpr.
#  Em runtime, uWebAssets.ExtrairWebAssets le esses recursos e recria os
#  arquivos em C:\Apolo\web (PASTA_WEB) ANTES da navegacao do WebView2, que
#  continua usando o virtual host  https://apolo.local/  -> C:\Apolo\web.
#
#  IMPORTANTE: rode este script SEMPRE que editar qualquer arquivo em .\web.
#  Editar so o html/css/js NAO atualiza o .res -> o .exe ficaria com a versao
#  antiga embutida.
#
#  Uso:   powershell -ExecutionPolicy Bypass -File gen-webassets.ps1
# ============================================================================

$ErrorActionPreference = 'Stop'

$ProjDir = $PSScriptRoot
$WebRoot = Join-Path $ProjDir 'web'

if (-not (Test-Path $WebRoot)) { throw "Pasta de assets nao encontrada: $WebRoot" }

# Localiza o brcc32 (compilador de recursos do Delphi).
function Find-Brcc32 {
    if ($env:BDS) {
        $p = Join-Path $env:BDS 'bin\brcc32.exe'
        if (Test-Path $p) { return $p }
    }
    $cand = Get-ChildItem 'C:\Program Files (x86)\Embarcadero\Studio\*\bin\brcc32.exe' -ErrorAction SilentlyContinue |
            Sort-Object FullName -Descending | Select-Object -First 1
    if ($cand) { return $cand.FullName }
    throw "brcc32.exe nao encontrado. Defina a variavel BDS ou instale o Delphi."
}

$Brcc32 = Find-Brcc32
Write-Host "brcc32: $Brcc32"

# Coleta os assets de .\web.
$arquivos = Get-ChildItem -Path $WebRoot -Recurse -File -Include *.html, *.css, *.js |
            Sort-Object FullName
if (-not $arquivos) { throw "Nenhum *.html/*.css/*.js encontrado em $WebRoot" }

$rcLinhas = New-Object System.Collections.Generic.List[string]
$manifestoLinhas = New-Object System.Collections.Generic.List[string]

# O manifesto e' ele proprio um recurso (lido primeiro em runtime).
$rcLinhas.Add('WEBMANIFEST RCDATA "ApoloWebAssets.manifest"')

$i = 0
foreach ($f in $arquivos) {
    $i++
    $resName = "WEBASSET_$i"

    # Caminho relativo a .\web (layout da extracao em C:\Apolo\web).
    $relWeb = $f.FullName.Substring($WebRoot.Length).TrimStart('\')

    # Caminho relativo a pasta do projeto (brcc32 roda aqui; o .rc vive aqui).
    $relProj = $f.FullName.Substring($ProjDir.Length).TrimStart('\')
    $relProjEsc = $relProj -replace '\\', '\\'

    $rcLinhas.Add("$resName RCDATA `"$relProjEsc`"")
    $manifestoLinhas.Add("$resName=$relWeb")
    Write-Host ("  {0,-12} <- web\{1}" -f $resName, $relWeb)
}

$manifestoPath = Join-Path $ProjDir 'ApoloWebAssets.manifest'
$rcPath = Join-Path $ProjDir 'ApoloWebAssets.rc'
$resPath = Join-Path $ProjDir 'ApoloWebAssets.res'

$utf8 = New-Object System.Text.UTF8Encoding($false)
[IO.File]::WriteAllText($manifestoPath, ($manifestoLinhas -join "`r`n") + "`r`n", $utf8)
[IO.File]::WriteAllText($rcPath, ($rcLinhas -join "`r`n") + "`r`n", $utf8)

Push-Location $ProjDir
try {
    & $Brcc32 'ApoloWebAssets.rc' '-foApoloWebAssets.res'
    if ($LASTEXITCODE -ne 0) { throw "brcc32 falhou (codigo $LASTEXITCODE)" }
}
finally { Pop-Location }

$tam = (Get-Item $resPath).Length
Write-Host ""
Write-Host ("OK: {0} ({1} arquivos, {2:N0} bytes)" -f $resPath, $arquivos.Count, $tam) -ForegroundColor Green
