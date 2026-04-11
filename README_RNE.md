# Consulta masiva RNE (TEL y COR)

Este flujo implementa la consulta masiva por archivo del manual tecnico RNE.

## Que hace el script

1. Recibe un CSV (telefonos o correos).
2. Lo comprime a ZIP.
3. Lo carga a `POST /excluidosback/archivo/cargar` con `type=TEL` o `type=COR`.
4. Toma el GUID devuelto por el servicio.
5. Hace polling a `GET /excluidosback/archivo/descargar/{GUID}`.
6. Descarga el ZIP de resultado cuando el proceso termina.

## Archivo principal

- `rne_bulk.ps1`
- `sap_to_rne_csv.ps1`

## Requisitos

- PowerShell 5.1 o superior
- Token JWT vigente del RNE
- CSV con una sola columna de datos (sin encabezado recomendado)

## Ejemplos de CSV

Telefono (`afiliados_tel.csv`):

```csv
3001234567
6012345678
```

Correo (`afiliados_cor.csv`):

```csv
persona1@correo.com
persona2@correo.com
```

## Uso

Consulta telefonos:

```powershell
.\rne_bulk.ps1 -Token "TU_TOKEN" -InputCsv ".\afiliados_tel.csv" -Type TEL -OutputDir ".\out"
```

Consulta correos:

```powershell
.\rne_bulk.ps1 -Token "TU_TOKEN" -InputCsv ".\afiliados_cor.csv" -Type COR -OutputDir ".\out"
```

Con tiempos personalizados:

```powershell
.\rne_bulk.ps1 -Token "TU_TOKEN" -InputCsv ".\afiliados_cor.csv" -Type COR -OutputDir ".\out" -PollSeconds 20 -MaxAttempts 180
```

## Integracion con SAP Business One

1. Exporta desde SAP B1 un CSV con columnas de correo y telefono.
2. Convierte y limpia con:

```powershell
.\sap_to_rne_csv.ps1 -InputCsv ".\sap_afiliados.csv" -EmailColumn "E_Mail" -PhoneColumn "Cellular"
```

3. Ejecuta TEL con el archivo generado:

```powershell
.\rne_bulk.ps1 -Token "TU_TOKEN" -InputCsv ".\out\afiliados_tel.csv" -Type TEL -OutputDir ".\out"
```

4. Ejecuta COR con el archivo generado:

```powershell
.\rne_bulk.ps1 -Token "TU_TOKEN" -InputCsv ".\out\afiliados_cor.csv" -Type COR -OutputDir ".\out"
```

5. Procesa el ZIP de salida y actualiza una tabla de auditoria en tu BD.

## Notas del manual

- Si un registro no aparece en la salida, se interpreta como no excluido en RNE.
- Solo el ultimo token generado queda activo.
- Recomiendan consultar despues de las 3:00 a.m. por la actualizacion diaria.
