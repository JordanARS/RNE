param(
    [Parameter(Mandatory = $true)]
    [string]$Token,

    [Parameter(Mandatory = $true)]
    [string]$InputCsv,

    [Parameter(Mandatory = $true)]
    [ValidateSet("TEL", "COR")]
    [string]$Type,

    [string]$OutputDir = ".\\out",
    [int]$PollSeconds = 15,
    [int]$MaxAttempts = 120
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

function Get-ErrorBody {
    param([System.Exception]$Exception)

    if (-not $Exception -or -not $Exception.Response) {
        return ""
    }

    try {
        $stream = $Exception.Response.GetResponseStream()
        if (-not $stream) { return "" }
        $reader = New-Object System.IO.StreamReader($stream)
        $body = $reader.ReadToEnd()
        $reader.Close()
        return $body
    }
    catch {
        return ""
    }
}

function Invoke-RneUpload {
    param(
        [string]$Token,
        [string]$ZipPath,
        [string]$Type
    )

    $uri = "https://tramitescrcom.gov.co/excluidosback/archivo/cargar"

    Write-Host "Subiendo archivo: $ZipPath"

    Add-Type -AssemblyName System.Net.Http
    $handler = New-Object System.Net.Http.HttpClientHandler
    $client = New-Object System.Net.Http.HttpClient($handler)

    try {
        $client.DefaultRequestHeaders.Authorization = New-Object System.Net.Http.Headers.AuthenticationHeaderValue("Bearer", $Token)

        $content = New-Object System.Net.Http.MultipartFormDataContent

        $fileBytes = [System.IO.File]::ReadAllBytes($ZipPath)
        $fileContent = New-Object System.Net.Http.ByteArrayContent -ArgumentList (, $fileBytes)
        $fileContent.Headers.ContentType = New-Object System.Net.Http.Headers.MediaTypeHeaderValue("application/zip")
        $null = $content.Add($fileContent, "file", [System.IO.Path]::GetFileName($ZipPath))

        $typeContent = New-Object System.Net.Http.StringContent($Type)
        $null = $content.Add($typeContent, "type")

        $response = $client.PostAsync($uri, $content).GetAwaiter().GetResult()
        $rawBody = $response.Content.ReadAsStringAsync().GetAwaiter().GetResult()

        if (-not $response.IsSuccessStatusCode) {
            throw "Error HTTP $([int]$response.StatusCode) en carga. Detalle: $rawBody"
        }

        $resp = $rawBody | ConvertFrom-Json
    }
    finally {
        if ($null -ne $content) { $content.Dispose() }
        if ($null -ne $client) { $client.Dispose() }
    }

    if (-not $resp) {
        throw "Respuesta vacia al cargar archivo."
    }

    $guid = $null
    if ($resp.data) {
        $guid = [string]$resp.data
    }
    elseif ($resp.message -and $resp.message -match "([A-Z0-9]{4}(?:-[A-Z0-9]{4}){3})") {
        $guid = $Matches[1]
    }

    if (-not $guid) {
        throw "No se pudo extraer el codigo GUI/GUID de la respuesta: $($resp | ConvertTo-Json -Depth 5 -Compress)"
    }

    return @{
        Guid = $guid
        Raw = $resp
    }
}

function Invoke-RneDownload {
    param(
        [string]$Token,
        [string]$Guid,
        [string]$OutZipPath,
        [int]$PollSeconds,
        [int]$MaxAttempts
    )

    $headers = @{ Authorization = "Bearer $Token" }
    $uri = "https://tramitescrcom.gov.co/excluidosback/archivo/descargar/$Guid"

    for ($i = 1; $i -le $MaxAttempts; $i++) {
        Write-Host "Intento $i/$MaxAttempts consultando estado..."
        try {
            Invoke-WebRequest -Method Get -Uri $uri -Headers $headers -OutFile $OutZipPath | Out-Null

            $size = (Get-Item -LiteralPath $OutZipPath).Length
            if ($size -gt 0) {
                Write-Host "Archivo resultado descargado: $OutZipPath ($size bytes)"
                return $true
            }

            throw "El archivo descargado esta vacio."
        }
        catch {
            $statusCode = $null
            if ($_.Exception.Response -and $_.Exception.Response.StatusCode) {
                $statusCode = [int]$_.Exception.Response.StatusCode
            }

            $errBody = Get-ErrorBody -Exception $_.Exception

            if ($statusCode -eq 409) {
                Write-Host "Aun en procesamiento (409). Esperando $PollSeconds segundos..."
                Start-Sleep -Seconds $PollSeconds
                continue
            }

            if ($statusCode -eq 403) {
                throw "Token invalido o vencido (403). Debes renovar token. Detalle: $errBody"
            }

            if ($statusCode) {
                throw "Error HTTP $statusCode consultando $uri. Detalle: $errBody"
            }

            throw "Error consultando descarga: $($_.Exception.Message)"
        }
    }

    throw "Se agoto el numero maximo de intentos ($MaxAttempts) sin obtener resultado procesado."
}

if (-not (Test-Path -LiteralPath $InputCsv)) {
    throw "No existe el CSV de entrada: $InputCsv"
}

if (-not (Test-Path -LiteralPath $OutputDir)) {
    New-Item -ItemType Directory -Path $OutputDir | Out-Null
}

$fullInputCsv = (Resolve-Path -LiteralPath $InputCsv).Path
$timestamp = Get-Date -Format "yyyyMMdd_HHmmss"
$zipPath = Join-Path $OutputDir ("input_{0}_{1}.zip" -f $Type, $timestamp)
$resultZipPath = Join-Path $OutputDir ("resultado_{0}_{1}.zip" -f $Type, $timestamp)

if (Test-Path -LiteralPath $zipPath) { Remove-Item -LiteralPath $zipPath -Force }

Write-Host "Empaquetando CSV a ZIP..."
Compress-Archive -LiteralPath $fullInputCsv -DestinationPath $zipPath -Force

$upload = Invoke-RneUpload -Token $Token -ZipPath $zipPath -Type $Type
$guid = $upload.Guid

Write-Host "Codigo de procesamiento (GUID): $guid"
Invoke-RneDownload -Token $Token -Guid $guid -OutZipPath $resultZipPath -PollSeconds $PollSeconds -MaxAttempts $MaxAttempts | Out-Null

Write-Host "Proceso completado."
Write-Host "ZIP enviado:     $zipPath"
Write-Host "ZIP resultado:   $resultZipPath"
Write-Host "GUID consulta:   $guid"
