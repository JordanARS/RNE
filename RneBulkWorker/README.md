# RneBulkWorker (.NET)

Worker para consulta masiva del RNE (TEL y COR) usando el flujo por archivo ZIP.

## Flujo

1. Lee correos y telefonos desde CSV, SQL o SAP Service Layer API.
2. Genera `input_cor.csv` y `input_tel.csv`.
3. Comprime cada archivo en ZIP.
4. Carga al endpoint de RNE `/archivo/cargar`.
5. Hace polling con GUID en `/archivo/descargar/{guid}`.
6. Descarga ZIP de resultado, lo extrae y genera auditoria.
7. Genera relacion por socio en `relacion_socios_rne.csv`.

## Configuracion

Edita `appsettings.json`:

- `Rne:Token`: token vigente.
- `Source:Mode`: `Csv`, `Sql` o `SapApi`.
- `Source:CsvPath`: ruta al CSV cuando se use archivo.
- `Source:SqlConnectionString`: conexion a SAP B1 SQL Server.
- `Source:SqlQuery`: debe retornar columnas `Email` y `Phone`.
- `SapServiceLayer:*`: parametros de conexion al Service Layer cuando `Source:Mode=SapApi`.

Ejemplo para usar API de SAP:

```json
"Source": {
	"Mode": "SapApi"
},
"SapServiceLayer": {
	"BaseUrl": "https://181.79.11.178:50000/b1s/v1",
	"CompanyDb": "SERFUNLLANOS_TEST",
	"UserName": "TU_USUARIO",
	"Password": "TU_CLAVE",
	"BusinessPartnersQuery": "/BusinessPartners?$select=CardCode,CardName,Phone1,Phone2,Cellular,EmailAddress&$filter=startswith(CardCode,'C')&$top=100000",
	"AllowInvalidCertificate": true
}
```

## Ejecucion

```powershell
cd .\RneBulkWorker
dotnet run
```

## Salidas

En `Run:OutputRoot` se crea una carpeta por ejecucion, por ejemplo:

- `runs\\20260317_120000\\cor\\input_cor.csv`
- `runs\\20260317_120000\\cor\\resultado_cor.zip`
- `runs\\20260317_120000\\cor\\auditoria_cor.csv`
- `runs\\20260317_120000\\tel\\input_tel.csv`
- `runs\\20260317_120000\\tel\\resultado_tel.zip`
- `runs\\20260317_120000\\tel\\auditoria_tel.csv`
- `runs\\20260317_120000\\relacion_socios_rne.csv`

## Notas

- `TreatPresenceAsExcluded=true` marca excluido cuando el dato aparece en la salida procesada.
- Si deseas ejecucion periodica, usa `Run:RunOnce=false` y define `Run:IntervalMinutes`.
- El worker no renueva token automaticamente; usa token vigente.
