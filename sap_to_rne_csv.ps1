param(
    [Parameter(Mandatory = $true)]
    [string]$InputCsv,

    [string]$EmailColumn = "Email",
    [string]$PhoneColumn = "Phone",
    [string]$OutputDir = ".\\out"
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

function Normalize-Email {
    param([string]$Value)

    if ([string]::IsNullOrWhiteSpace($Value)) { return $null }
    $v = $Value.Trim().ToLowerInvariant()
    if ($v -match "^[^@\s]+@[^@\s]+\.[^@\s]+$") {
        return $v
    }
    return $null
}

function Normalize-Phone {
    param([string]$Value)

    if ([string]::IsNullOrWhiteSpace($Value)) { return $null }
    $digits = ($Value -replace "\D", "")
    if ([string]::IsNullOrWhiteSpace($digits)) { return $null }

    # Mantiene el numero en formato solo digitos para evitar errores de parsing en RNE.
    if ($digits.Length -ge 7) {
        return $digits
    }

    return $null
}

if (-not (Test-Path -LiteralPath $InputCsv)) {
    throw "No existe el archivo de entrada: $InputCsv"
}

if (-not (Test-Path -LiteralPath $OutputDir)) {
    New-Item -ItemType Directory -Path $OutputDir | Out-Null
}

$rows = Import-Csv -LiteralPath $InputCsv
if (-not $rows) {
    throw "El CSV de entrada no tiene filas: $InputCsv"
}

$emails = New-Object System.Collections.Generic.HashSet[string]
$phones = New-Object System.Collections.Generic.HashSet[string]

foreach ($row in $rows) {
    $emailRaw = $null
    $phoneRaw = $null

    if ($row.PSObject.Properties.Name -contains $EmailColumn) {
        $emailRaw = [string]$row.$EmailColumn
    }

    if ($row.PSObject.Properties.Name -contains $PhoneColumn) {
        $phoneRaw = [string]$row.$PhoneColumn
    }

    $email = Normalize-Email -Value $emailRaw
    if ($email) { $null = $emails.Add($email) }

    $phone = Normalize-Phone -Value $phoneRaw
    if ($phone) { $null = $phones.Add($phone) }
}

$emailsPath = Join-Path $OutputDir "afiliados_cor.csv"
$phonesPath = Join-Path $OutputDir "afiliados_tel.csv"

$emails | Sort-Object | Set-Content -LiteralPath $emailsPath -Encoding UTF8
$phones | Sort-Object | Set-Content -LiteralPath $phonesPath -Encoding UTF8

Write-Host "Registros unicos COR: $($emails.Count)"
Write-Host "Registros unicos TEL: $($phones.Count)"
Write-Host "Archivo COR: $emailsPath"
Write-Host "Archivo TEL: $phonesPath"
