param(
    [string]$SapJsonPath = ".\\out\\sap_businesspartners_20260318_115218.json",
    [string]$AppSettingsPath = ".\\appsettings.json",
    [string]$OutputDir = ".\\out",
    [int]$BatchSize = 5000
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

        $payload = @{
            type = $Type
            keys = $batch
        } | ConvertTo-Json -Depth 6 -Compress

        $tmpPayload = Join-Path $env:TEMP ("rne_{0}_{1}.json" -f $Type.ToLowerInvariant(), [guid]::NewGuid().ToString("N"))
        Set-Content -Path $tmpPayload -Value $payload -Encoding ASCII

        try {
            $response = curl.exe -s -X POST $endpoint -H "Content-Type: application/json" -H "Authorization: Bearer $Token" --data-binary "@$tmpPayload"
            $items = @()
            if (-not [string]::IsNullOrWhiteSpace($response)) {
                $parsed = $response | ConvertFrom-Json
                if ($parsed -is [System.Array]) {
                    $items = $parsed
                }
                elseif ($null -ne $parsed) {
                    $items = @($parsed)
                }
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
    }

    return $result
}

if (-not (Test-Path -LiteralPath $SapJsonPath)) {
    throw "No existe archivo SAP JSON: $SapJsonPath"
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

$sap = Get-Content -Raw $SapJsonPath | ConvertFrom-Json
$partners = @($sap.value)
if ($partners.Count -eq 0) {
    throw "No se encontraron socios en el JSON de SAP."
}

$emailSet = @{}
$phoneSet = @{}

$partnerRows = New-Object System.Collections.Generic.List[object]

foreach ($p in $partners) {
    $phone1 = Normalize-Phone -Value ([string]$p.Phone1)
    $phone2 = Normalize-Phone -Value ([string]$p.Phone2)
    $cell = Normalize-Phone -Value ([string]$p.Cellular)
    $email = Normalize-Email -Value ([string]$p.EmailAddress)

    if ($phone1) { $phoneSet[$phone1] = $true }
    if ($phone2) { $phoneSet[$phone2] = $true }
    if ($cell) { $phoneSet[$cell] = $true }
    if ($email) { $emailSet[$email] = $true }

    [void]$partnerRows.Add([pscustomobject]@{
        CardCode = [string]$p.CardCode
        CardName = [string]$p.CardName
        Phone1 = $phone1
        Phone2 = $phone2
        Cellular = $cell
        EmailAddress = $email
    })
}

$emailKeys = [string[]]$emailSet.Keys
$phoneKeys = [string[]]$phoneSet.Keys

Write-Host "Consultando RNE: COR=$($emailKeys.Count), TEL=$($phoneKeys.Count)"

$emailMap = Invoke-RneQuery -Token $token -Type COR -Keys $emailKeys -BatchSize $BatchSize
$phoneMap = Invoke-RneQuery -Token $token -Type TEL -Keys $phoneKeys -BatchSize $BatchSize

function Get-PhoneStatus {
    param([string]$Phone, [hashtable]$Map)

    if ([string]::IsNullOrWhiteSpace($Phone)) { return "SIN_DATO" }
    if (-not $Map.ContainsKey($Phone)) { return "No registrado en el RNE" }

    $op = $Map[$Phone].opcionesContacto
    if ($null -ne $op.llamada) {
        if ([bool]$op.llamada -eq $false) { return "No llamar" }
        return "Habilitado" 
    }

    return "Registrado en RNE"
}

function Get-EmailStatus {
    param([string]$Email, [hashtable]$Map)

    if ([string]::IsNullOrWhiteSpace($Email)) { return "SIN_DATO" }
    if (-not $Map.ContainsKey($Email)) { return "No registrado en el RNE" }

    $op = $Map[$Email].opcionesContacto
    if ($null -ne $op.correo_electronico) {
        if ([bool]$op.correo_electronico -eq $false) { return "No enviar correo" }
        return "Habilitado"
    }

    return "Registrado en RNE"
}

$outRows = foreach ($row in $partnerRows) {
    $s1 = Get-PhoneStatus -Phone $row.Phone1 -Map $phoneMap
    $s2 = Get-PhoneStatus -Phone $row.Phone2 -Map $phoneMap
    $s3 = Get-PhoneStatus -Phone $row.Cellular -Map $phoneMap
    $se = Get-EmailStatus -Email $row.EmailAddress -Map $emailMap

    $isBlocked = @($s1, $s2, $s3, $se) -contains "No llamar" -or @($s1, $s2, $s3, $se) -contains "No enviar correo"
    $general = if ($isBlocked) { "NO CONTACTAR" } else { "HABILITADO" }

    [pscustomobject]@{
        CardCode = $row.CardCode
        CardName = $row.CardName
        Phone1 = $row.Phone1
        Phone1Estado = $s1
        Phone2 = $row.Phone2
        Phone2Estado = $s2
        Cellular = $row.Cellular
        CellularEstado = $s3
        EmailAddress = $row.EmailAddress
        EmailEstado = $se
        EstadoGeneral = $general
    }
}

$timestamp = Get-Date -Format "yyyyMMdd_HHmmss"
$outCsv = Join-Path $OutputDir ("resultado_rne_socios_{0}.csv" -f $timestamp)
$outJson = Join-Path $OutputDir ("resultado_rne_socios_{0}.json" -f $timestamp)

$outRows | Export-Csv -Path $outCsv -NoTypeInformation -Encoding UTF8
$outRows | ConvertTo-Json -Depth 6 | Set-Content -Path $outJson -Encoding UTF8

Write-Host "Proceso completado."
Write-Host "Socios evaluados: $($partnerRows.Count)"
Write-Host "Coincidencias COR en RNE: $($emailMap.Count)"
Write-Host "Coincidencias TEL en RNE: $($phoneMap.Count)"
Write-Host "Salida CSV: $outCsv"
Write-Host "Salida JSON: $outJson"
