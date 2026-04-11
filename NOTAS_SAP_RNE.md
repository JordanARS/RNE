# Notas de Conexion SAP Service Layer y RNE

Fecha: 2026-03-17

## Estado de conexion SAP Service Layer

- Endpoint validado: `POST /b1s/v1/Login`
- URL: `https://int.serfunllanos.com:50000/b1s/v1/Login`
- Resultado final de prueba: `HTTP 200 OK`
- Respuesta recibida: `SessionId` y cookie `B1SESSION` (autenticacion exitosa)

## Hallazgo tecnico de pruebas

- Una invocacion inicial en PowerShell devolvio error por formato del body.
- El request correcto se logro enviando JSON valido como payload binario (`--data-binary`) con `Content-Type: application/json`.
- Con formato correcto, SAP autentico sin problema.

## Riesgos observados en el plugin compartido

- Credenciales hardcodeadas en codigo.
- Endpoint REST publico sin restriccion estricta.
- SSL verification desactivada.

## Pendiente para siguiente fase

- Crear accion `pingSap` (solo prueba de conexion) en el plugin.
- Separar accion de consulta real y protegerla con permisos/nonce.
- Mover credenciales a variables seguras (config/env).

## Nota operativa

- No almacenar tokens/sesiones en logs ni en archivos de auditoria.
