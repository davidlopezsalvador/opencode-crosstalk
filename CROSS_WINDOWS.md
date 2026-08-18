# CROSS_WINDOWS — Pitfalls de PowerShell 5.1 / Windows

Pitfalls específicos de entorno (Windows + PowerShell 5.1), consolidados el
2026-08-11 tras revisión externa (separados de `CROSS_TALK.md` el 2026-08-11
para que ese documento contenga solo reglas de protocolo). Son limitaciones de
la plataforma, NO del protocolo. La sección 11 de `CROSS_TALK.md` los cita
(ítems 1, 2, 7, 8) y delega el detalle aquí.

1. **JSON corrupto / HTTP 500** al usar `-d '...'` inline en PowerShell: el
   quoting de PS 5.1 corrompe el body. Usar archivo temporal + `--data-binary`
   (sección 4) o el wrapper `send_message.ps1` (4e).
2. **Mojibake** (acentos como `?`): la salida de la API se lee en la cp850 de
   PS 5.1 aunque el body sea UTF-8. Enviar en ASCII plano y corregir al
   integrar; o leer con `HttpClient`/`Invoke-RestMethod` que decodifican UTF-8
   correctamente.
3. **BOM en JSON → HTTP 500** (v1.5, probado 2026-08-10): generar el payload
   con `[System.Text.Encoding]::UTF8` (que escribe BOM) provoca `HTTP 500
   Unexpected server error`. Usar UTF-8 sin BOM o ASCII (sección 4).
4. **Rutas `/tmp/`:** no existen en Windows; usar `$env:TEMP`.
5. **`&&` en PowerShell 5.1:** no existe; usar `;` o comandos separados.
6. **`Add-Content` con escritura concurrente** (hallazgo T10, 2026-08-11):
   es atómico (todo-o-nada) pero usa bloqueo exclusivo por llamada; dos
   procesos a la vez → el segundo recibe `IOException` y pierde su línea
   silenciosamente. Por eso el outbox lo actualiza SOLO el emisor (12.2); si
   se necesitara escritura concurrente real, usar append con reintento con
   backoff o archivo de lock.
7. **Interpolación `${var}:`** en strings de PowerShell: `"${var}:foo"` se
   interpreta como variable de scope `${var:}`; escapar como `` `${var}`:foo ``.
8. **Stub de Python de Windows Store:** `python` en el PATH de un shell normal
   es el alias de la Store y NO ejecuta; el real está en
   `AppData\Local\Python\pythoncore-3.11-64` (8.2). Indicar rutas completas.
