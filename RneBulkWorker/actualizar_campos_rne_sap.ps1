param(
    [string]$InputPath = ".\\out\\resultado_rne_socios_20260318_150054.json",
    [string]$AppSettingsPath = ".\\appsettings.json",
    [int]$Top = 300,
    [string]$OutputDir = ".\\out",
    [switch]$OnlyWithRne,
    [switch]$Apply
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

function New-TempFilePath {
    param([string]$Prefix, [string]$Extension)
    return (Join-Path $env:TEMP ("{0}_{1}.{2}" -f $Prefix, [guid]::NewGuid().ToString("N"), $Extension))
}

function Load-InputRows {
    param([string]$Path)

    if (-not (Test-Path -LiteralPath $Path)) {
        throw "No existe archivo de entrada: $Path"
    }

    $ext = [System.IO.Path]::GetExtension($Path).ToLowerInvariant()
    if ($ext -eq ".csv") {
        return @(Import-Csv -Path $Path)
    }

    if ($ext -eq ".json") {
        $obj = Get-Content -Raw $Path | ConvertFrom-Json
        if ($obj -is [System.Array]) {
            return @($obj)
        }
        return @($obj)
    }

    throw "Formato no soportado. Use .csv o .json"
}

function Invoke-SapLogin {
    param(
        [string]$BaseUrl,
        [string]$CompanyDb,
        [string]$UserName,
        [string]$Password,
        [bool]$AllowInvalidCertificate,
        [string]$CookieJarPath
    )

    $payloadPath = New-TempFilePath -Prefix "sap_login" -Extension "json"
    $respPath = New-TempFilePath -Prefix "sap_login_resp" -Extension "json"

    try {
        $payload = @{ CompanyDB = $CompanyDb; UserName = $UserName; Password = $Password } | ConvertTo-Json -Compress
        Set-Content -Path $payloadPath -Value $payload -Encoding ASCII

        $curlArgs = @()
        if ($AllowInvalidCertificate) { $curlArgs += "-k" }
        $curlArgs += @("-s", "-c", $CookieJarPath, "-X", "POST", ($BaseUrl + "/Login"), "-H", "Content-Type: application/json", "--data-binary", ("@" + $payloadPath), "-o", $respPath)
        & curl.exe @curlArgs | Out-Null

        $text = Get-Content -Raw $respPath
        $obj = $null
        try { $obj = $text | ConvertFrom-Json } catch {}

        if ($null -eq $obj -or [string]::IsNullOrWhiteSpace([string]$obj.SessionId)) {
            throw "No fue posible autenticarse en SAP Service Layer. Respuesta: $text"
        }
    }
    finally {
        Remove-Item -Path $payloadPath -Force -ErrorAction SilentlyContinue
        Remove-Item -Path $respPath -Force -ErrorAction SilentlyContinue
    }
}

function Invoke-SapPatch {
    param(
        [string]$BaseUrl,
        [bool]$AllowInvalidCertificate,
        [string]$CookieJarPath,
        [string]$CardCode,
        [hashtable]$Payload
    )

    $payloadPath = New-TempFilePath -Prefix "sap_patch" -Extension "json"
    $respPath = New-TempFilePath -Prefix "sap_patch_resp" -Extension "json"

    try {
        $body = $Payload | ConvertTo-Json -Depth 5 -Compress
        Set-Content -Path $payloadPath -Value $body -Encoding ASCII

        $url = "{0}/BusinessPartners('{1}')" -f $BaseUrl, $CardCode

        $curlArgs = @()
        if ($AllowInvalidCertificate) { $curlArgs += "-k" }
        $curlArgs += @("-s", "-b", $CookieJarPath, "-X", "PATCH", $url, "-H", "Content-Type: application/json", "--data-binary", ("@" + $payloadPath), "-o", $respPath, "-w", "%{http_code}")

        $httpCode = (& curl.exe @curlArgs)
        $responseText = Get-Content -Raw $respPath -ErrorAction SilentlyContinue

        return [pscustomobject]@{
            HttpCode = [string]$httpCode
            Body = $responseText
        }
    }
    finally {
        Remove-Item -Path $payloadPath -Force -ErrorAction SilentlyContinue
        Remove-Item -Path $respPath -Force -ErrorAction SilentlyContinue
    }
}

function Convert-ToSapUdfValue {
    param([string]$Value)

    if ([string]::IsNullOrWhiteSpace($Value)) {
        return "SIN_DATO"
    }

    $v = $Value.Trim()
    switch -Exact ($v) {
        "No llamar" { return "NO_LLAMAR" }
        "Habilitado" { return "HABILITADO" }
        "No registrado en el RNE" { return "NO_INFO" }
        "No enviar correo" { return "NO_CORREO" }
        "SIN_DATO" { return "SIN_DATO" }
        "Registrado en RNE" { return "EN_RNE" }
        default {
            if ($v.Length -gt 10) {
                return $v.Substring(0, 10)
            }
            return $v
        }
    }
}

function Test-HasRneMatch {
    param([object]$Row)

    $states = @(
        [string]$Row.Phone1Estado,
        [string]$Row.Phone2Estado,
        [string]$Row.CellularEstado,
        [string]$Row.EmailEstado
    )

    foreach ($s in $states) {
        $v = $s.Trim()
        if ([string]::IsNullOrWhiteSpace($v)) {
            continue
        }

        if ($v -ne "SIN_DATO" -and $v -ne "No registrado en el RNE" -and $v -ne "NO_INFO") {
            return $true
        }
    }

    return $false
}

if (-not (Test-Path -LiteralPath $OutputDir)) {
    New-Item -Path $OutputDir -ItemType Directory | Out-Null
}

$rows = Load-InputRows -Path $InputPath
if ($rows.Count -eq 0) {
    throw "El archivo de entrada no tiene filas."
}

$selected = @($rows | Select-Object -First $Top)
Write-Host ("Filas seleccionadas para procesar: {0}" -f $selected.Count)

$candidates = $selected
if ($OnlyWithRne) {
    $candidates = @($selected | Where-Object { Test-HasRneMatch -Row $_ })
    Write-Host ("Filas con al menos una coincidencia en RNE: {0}" -f $candidates.Count)
}

$preTs = Get-Date -Format "yyyyMMdd_HHmmss"
$candidatesPath = Join-Path $OutputDir ("candidatos_actualizacion_sap_rne_{0}.csv" -f $preTs)
$candidates | Select-Object CardCode,CardName,Phone1Estado,Phone2Estado,CellularEstado,EmailEstado,EstadoGeneral | Export-Csv -Path $candidatesPath -NoTypeInformation -Encoding UTF8
Write-Host ("Archivo de candidatos: {0}" -f $candidatesPath)

$settings = Get-Content -Raw $AppSettingsPath | ConvertFrom-Json
$sap = $settings.SapServiceLayer
$baseUrl = [string]$sap.BaseUrl
$companyDb = [string]$sap.CompanyDb
$userName = [string]$sap.UserName
$password = [string]$sap.Password
$allowInvalidCertificate = [bool]$sap.AllowInvalidCertificate

if ([string]::IsNullOrWhiteSpace($baseUrl) -or [string]::IsNullOrWhiteSpace($companyDb) -or [string]::IsNullOrWhiteSpace($userName) -or [string]::IsNullOrWhiteSpace($password)) {
    throw "Configura SapServiceLayer (BaseUrl, CompanyDb, UserName, Password) en appsettings."
}

$cookieJar = New-TempFilePath -Prefix "sap_cookie" -Extension "txt"
$report = New-Object System.Collections.Generic.List[object]

try {
    Invoke-SapLogin -BaseUrl $baseUrl -CompanyDb $companyDb -UserName $userName -Password $password -AllowInvalidCertificate $allowInvalidCertificate -CookieJarPath $cookieJar

    foreach ($r in $candidates) {
        $cardCode = [string]$r.CardCode
        if ([string]::IsNullOrWhiteSpace($cardCode)) {
            continue
        }

        $payload = @{
            U_rne_tel1 = Convert-ToSapUdfValue -Value ([string]$r.Phone1Estado)
            U_rne_tel2 = Convert-ToSapUdfValue -Value ([string]$r.Phone2Estado)
            U_rne_cel = Convert-ToSapUdfValue -Value ([string]$r.CellularEstado)
            U_rne_correo = Convert-ToSapUdfValue -Value ([string]$r.EmailEstado)
        }

        if (-not $Apply) {
            Write-Host ("DRY-RUN {0} => {1}" -f $cardCode, ($payload | ConvertTo-Json -Compress))
            [void]$report.Add([pscustomobject]@{
                CardCode = $cardCode
                Resultado = "DRY-RUN"
                HttpCode = ""
                Mensaje = "No aplicado"
            })
            continue
        }

        $resp = Invoke-SapPatch -BaseUrl $baseUrl -AllowInvalidCertificate $allowInvalidCertificate -CookieJarPath $cookieJar -CardCode $cardCode -Payload $payload
        $ok = ($resp.HttpCode -eq "204" -or $resp.HttpCode -eq "200")

        if ($ok) {
            Write-Host ("OK {0} HTTP {1}" -f $cardCode, $resp.HttpCode)
            [void]$report.Add([pscustomobject]@{
                CardCode = $cardCode
                Resultado = "OK"
                HttpCode = $resp.HttpCode
                Mensaje = "Actualizado"
            })
        }
        else {
            Write-Warning ("ERROR {0} HTTP {1}: {2}" -f $cardCode, $resp.HttpCode, $resp.Body)
            [void]$report.Add([pscustomobject]@{
                CardCode = $cardCode
                Resultado = "ERROR"
                HttpCode = $resp.HttpCode
                Mensaje = $resp.Body
            })
        }
    }
}
finally {
    Remove-Item -Path $cookieJar -Force -ErrorAction SilentlyContinue
}

$ts = Get-Date -Format "yyyyMMdd_HHmmss"
$outCsv = Join-Path $OutputDir ("actualizacion_sap_rne_{0}.csv" -f $ts)
$report | Export-Csv -Path $outCsv -NoTypeInformation -Encoding UTF8

Write-Host "Proceso terminado."
Write-Host ("Reporte: {0}" -f $outCsv)
if (-not $Apply) {
    Write-Host "Modo DRY-RUN: no se aplicaron cambios en SAP."
}
