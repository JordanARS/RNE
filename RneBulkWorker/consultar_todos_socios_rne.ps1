param(
    [string]$AppSettingsPath = ".\\appsettings.json",
    [string]$OutputDir = ".\\out",
    [int]$SapPageSize = 1000,
    [int]$RneBatchSize = 5000,
    [string]$CardCodePrefix = "C"
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

function Normalize-Phone {
    param([string]$Value)

    if ([string]::IsNullOrWhiteSpace($Value)) { return $null }
    $digits = ($Value -replace "\D", "")
    if ($digits.Length -lt 7) { return $null }
    return $digits
}

function Normalize-Email {
    param([string]$Value)

    if ([string]::IsNullOrWhiteSpace($Value)) { return $null }
    $email = $Value.Trim().ToLowerInvariant()
    if ($email -notmatch "^[^@\s]+@[^@\s]+\.[^@\s]+$") { return $null }
    return $email
}

function New-TempFilePath {
    param([string]$Prefix, [string]$Extension)

    return (Join-Path $env:TEMP ("{0}_{1}.{2}" -f $Prefix, [guid]::NewGuid().ToString("N"), $Extension))
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
    $headersPath = New-TempFilePath -Prefix "sap_login_headers" -Extension "txt"
    $respPath = New-TempFilePath -Prefix "sap_login_resp" -Extension "json"

    try {
        $payload = @{ CompanyDB = $CompanyDb; UserName = $UserName; Password = $Password } | ConvertTo-Json -Compress
        Set-Content -Path $payloadPath -Value $payload -Encoding ASCII

        $curlArgs = @()
        if ($AllowInvalidCertificate) { $curlArgs += "-k" }
        $curlArgs += @("-s", "-D", $headersPath, "-c", $CookieJarPath, "-X", "POST", ($BaseUrl + "/Login"), "-H", "Content-Type: application/json", "--data-binary", ("@" + $payloadPath), "-o", $respPath)

        & curl.exe @curlArgs | Out-Null

        $text = Get-Content -Raw $respPath
        $obj = $null
        try { $obj = $text | ConvertFrom-Json } catch {}

        if ($null -eq $obj -or [string]::IsNullOrWhiteSpace([string]$obj.SessionId)) {
            throw "No fue posible autenticarse en SAP Service Layer. Respuesta: $text"
        }

        return $obj
    }
    finally {
        Remove-Item -Path $payloadPath -Force -ErrorAction SilentlyContinue
        Remove-Item -Path $headersPath -Force -ErrorAction SilentlyContinue
        Remove-Item -Path $respPath -Force -ErrorAction SilentlyContinue
    }
}

function Invoke-SapBusinessPartnersPage {
    param(
        [string]$BaseUrl,
        [string]$CookieJarPath,
        [bool]$AllowInvalidCertificate,
        [int]$Top,
        [int]$Skip,
        [string]$CardCodePrefix
    )

    $outPath = New-TempFilePath -Prefix "sap_bp_page" -Extension "json"
    try {
        $query = "{0}/BusinessPartners?`$select=CardCode,CardName,Phone1,Phone2,Cellular,EmailAddress&`$filter=startswith(CardCode,'{1}')&`$top={2}&`$skip={3}" -f $BaseUrl, $CardCodePrefix, $Top, $Skip

        $curlArgs = @()
        if ($AllowInvalidCertificate) { $curlArgs += "-k" }
        $curlArgs += @("-s", "-b", $CookieJarPath, $query, "-H", "Prefer: odata.maxpagesize=100000", "-o", $outPath, "-w", "%{http_code}")

        $code = (& curl.exe @curlArgs)
        if ($code -ne "200") {
            $err = Get-Content -Raw $outPath
            throw "Error SAP BusinessPartners HTTP $code. Respuesta: $err"
        }

        $jsonText = Get-Content -Raw $outPath
        return ($jsonText | ConvertFrom-Json)
    }
    finally {
        Remove-Item -Path $outPath -Force -ErrorAction SilentlyContinue
    }
}

function Invoke-RneQuery {
    param(
        [string]$Token,
        [ValidateSet("COR", "TEL")]
        [string]$Type,
        [string[]]$Keys,
        [int]$BatchSize
    )

    $result = @{}
    $allKeys = @($Keys | Where-Object { -not [string]::IsNullOrWhiteSpace($_) })
    if ($allKeys.Count -eq 0) {
        return $result
    }

    $endpoint = "https://tramitescrcom.gov.co/excluidosback/consultaMasiva/validarExcluidos"

    for ($i = 0; $i -lt $allKeys.Count; $i += $BatchSize) {
        $end = [Math]::Min($i + $BatchSize - 1, $allKeys.Count - 1)
        $batch = @($allKeys[$i..$end])

        $payload = @{ type = $Type; keys = $batch } | ConvertTo-Json -Depth 6 -Compress
        $tmpPayload = New-TempFilePath -Prefix ("rne_" + $Type.ToLowerInvariant()) -Extension "json"

        try {
            Set-Content -Path $tmpPayload -Value $payload -Encoding ASCII

            $response = & curl.exe -s -X POST $endpoint -H "Content-Type: application/json" -H "Authorization: Bearer $Token" --data-binary ("@" + $tmpPayload)

            if ([string]::IsNullOrWhiteSpace($response)) {
                continue
            }

            $parsed = $response | ConvertFrom-Json
            $items = @()
            if ($parsed -is [System.Array]) {
                $items = $parsed
            }
            elseif ($null -ne $parsed) {
                $items = @($parsed)
            }

            foreach ($item in $items) {
                if ($null -eq $item) {
                    continue
                }

                $keyProp = $item.PSObject.Properties["llave"]
                if ($null -ne $keyProp -and -not [string]::IsNullOrWhiteSpace([string]$keyProp.Value)) {
                    $result[[string]$keyProp.Value] = $item
                    continue
                }

                $msgProp = $item.PSObject.Properties["message"]
                if ($null -ne $msgProp) {
                    Write-Warning ("RNE {0} devolvio mensaje sin llave: {1}" -f $Type, [string]$msgProp.Value)
                }
            }
        }
        finally {
            Remove-Item -Path $tmpPayload -Force -ErrorAction SilentlyContinue
        }

        Write-Host ("RNE {0} lote {1}-{2} de {3}" -f $Type, ($i + 1), ($end + 1), $allKeys.Count)
    }

    return $result
}

function Get-PhoneStatus {
    param([string]$PhoneNormalized, [hashtable]$Map)

    if ([string]::IsNullOrWhiteSpace($PhoneNormalized)) { return "SIN_DATO" }
    if (-not $Map.ContainsKey($PhoneNormalized)) { return "No registrado en el RNE" }

    $op = $Map[$PhoneNormalized].opcionesContacto
    if ($null -ne $op.llamada) {
        if ([bool]$op.llamada -eq $false) { return "No llamar" }
        return "Habilitado"
    }

    return "Registrado en RNE"
}

function Get-EmailStatus {
    param([string]$EmailNormalized, [hashtable]$Map)

    if ([string]::IsNullOrWhiteSpace($EmailNormalized)) { return "SIN_DATO" }
    if (-not $Map.ContainsKey($EmailNormalized)) { return "No registrado en el RNE" }

    $op = $Map[$EmailNormalized].opcionesContacto
    if ($null -ne $op.correo_electronico) {
        if ([bool]$op.correo_electronico -eq $false) { return "No enviar correo" }
        return "Habilitado"
    }

    return "Registrado en RNE"
}

if (-not (Test-Path -LiteralPath $AppSettingsPath)) {
    throw "No existe appsettings: $AppSettingsPath"
}
if (-not (Test-Path -LiteralPath $OutputDir)) {
    New-Item -Path $OutputDir -ItemType Directory | Out-Null
}

$settings = Get-Content -Raw $AppSettingsPath | ConvertFrom-Json
$token = [string]$settings.Rne.Token
if ([string]::IsNullOrWhiteSpace($token)) {
    throw "Token RNE vacio en appsettings."
}

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

try {
    Write-Host "Autenticando en SAP Service Layer..."
    [void](Invoke-SapLogin -BaseUrl $baseUrl -CompanyDb $companyDb -UserName $userName -Password $password -AllowInvalidCertificate $allowInvalidCertificate -CookieJarPath $cookieJar)

    $partnerRows = New-Object System.Collections.Generic.List[object]
    $emailSet = @{}
    $phoneSet = @{}

    $skip = 0
    $page = 0

    while ($true) {
        $page++
        $sapPage = Invoke-SapBusinessPartnersPage -BaseUrl $baseUrl -CookieJarPath $cookieJar -AllowInvalidCertificate $allowInvalidCertificate -Top $SapPageSize -Skip $skip -CardCodePrefix $CardCodePrefix
        $items = @($sapPage.value)
        $count = $items.Count

        Write-Host ("SAP pagina {0}: {1} registros (skip={2})" -f $page, $count, $skip)

        if ($count -eq 0) {
            break
        }

        foreach ($p in $items) {
            $phone1Raw = [string]$p.Phone1
            $phone2Raw = [string]$p.Phone2
            $cellRaw = [string]$p.Cellular
            $emailRaw = [string]$p.EmailAddress

            $phone1 = Normalize-Phone -Value $phone1Raw
            $phone2 = Normalize-Phone -Value $phone2Raw
            $cell = Normalize-Phone -Value $cellRaw
            $email = Normalize-Email -Value $emailRaw

            if ($phone1) { $phoneSet[$phone1] = $true }
            if ($phone2) { $phoneSet[$phone2] = $true }
            if ($cell) { $phoneSet[$cell] = $true }
            if ($email) { $emailSet[$email] = $true }

            [void]$partnerRows.Add([pscustomobject]@{
                CardCode = [string]$p.CardCode
                CardName = [string]$p.CardName
                Phone1Raw = $phone1Raw
                Phone2Raw = $phone2Raw
                CellularRaw = $cellRaw
                EmailRaw = $emailRaw
                Phone1 = $phone1
                Phone2 = $phone2
                Cellular = $cell
                EmailAddress = $email
            })
        }

        $skip += $count
        if ($count -lt $SapPageSize) {
            break
        }
    }

    $emailKeys = [string[]]$emailSet.Keys
    $phoneKeys = [string[]]$phoneSet.Keys

    Write-Host ("Consultando RNE: socios={0}, COR={1}, TEL={2}" -f $partnerRows.Count, $emailKeys.Count, $phoneKeys.Count)

    $emailMap = Invoke-RneQuery -Token $token -Type COR -Keys $emailKeys -BatchSize $RneBatchSize
    $phoneMap = Invoke-RneQuery -Token $token -Type TEL -Keys $phoneKeys -BatchSize $RneBatchSize

    $outRows = foreach ($row in $partnerRows) {
        $s1 = Get-PhoneStatus -PhoneNormalized $row.Phone1 -Map $phoneMap
        $s2 = Get-PhoneStatus -PhoneNormalized $row.Phone2 -Map $phoneMap
        $s3 = Get-PhoneStatus -PhoneNormalized $row.Cellular -Map $phoneMap
        $se = Get-EmailStatus -EmailNormalized $row.EmailAddress -Map $emailMap

        $isBlocked = @($s1, $s2, $s3, $se) -contains "No llamar" -or @($s1, $s2, $s3, $se) -contains "No enviar correo"
        $general = if ($isBlocked) { "NO CONTACTAR" } else { "HABILITADO" }

        [pscustomobject]@{
            CardCode = $row.CardCode
            CardName = $row.CardName
            Phone1 = $row.Phone1Raw
            Phone1Estado = $s1
            Phone2 = $row.Phone2Raw
            Phone2Estado = $s2
            Cellular = $row.CellularRaw
            CellularEstado = $s3
            EmailAddress = $row.EmailRaw
            EmailEstado = $se
            EstadoGeneral = $general
        }
    }

    $timestamp = Get-Date -Format "yyyyMMdd_HHmmss"
    $csvPath = Join-Path $OutputDir ("resultado_rne_socios_todos_{0}.csv" -f $timestamp)
    $jsonPath = Join-Path $OutputDir ("resultado_rne_socios_todos_{0}.json" -f $timestamp)
    $summaryPath = Join-Path $OutputDir ("resumen_rne_socios_todos_{0}.txt" -f $timestamp)

    $outRows | Export-Csv -Path $csvPath -NoTypeInformation -Encoding UTF8
    $outRows | ConvertTo-Json -Depth 6 | Set-Content -Path $jsonPath -Encoding UTF8

    $total = @($outRows).Count
    $noContactar = @($outRows | Where-Object { $_.EstadoGeneral -eq "NO CONTACTAR" }).Count
    $habilitado = @($outRows | Where-Object { $_.EstadoGeneral -eq "HABILITADO" }).Count

    @(
        ("Total socios evaluados: {0}" -f $total),
        ("Coincidencias COR en RNE: {0}" -f $emailMap.Count),
        ("Coincidencias TEL en RNE: {0}" -f $phoneMap.Count),
        ("NO CONTACTAR: {0}" -f $noContactar),
        ("HABILITADO: {0}" -f $habilitado),
        ("CSV: {0}" -f $csvPath),
        ("JSON: {0}" -f $jsonPath)
    ) | Set-Content -Path $summaryPath -Encoding UTF8

    Write-Host "Proceso completado."
    Write-Host ("Total socios evaluados: {0}" -f $total)
    Write-Host ("Coincidencias COR en RNE: {0}" -f $emailMap.Count)
    Write-Host ("Coincidencias TEL en RNE: {0}" -f $phoneMap.Count)
    Write-Host ("NO CONTACTAR: {0}" -f $noContactar)
    Write-Host ("HABILITADO: {0}" -f $habilitado)
    Write-Host ("Salida CSV: {0}" -f $csvPath)
    Write-Host ("Salida JSON: {0}" -f $jsonPath)
    Write-Host ("Resumen: {0}" -f $summaryPath)
}
finally {
    Remove-Item -Path $cookieJar -Force -ErrorAction SilentlyContinue
}
