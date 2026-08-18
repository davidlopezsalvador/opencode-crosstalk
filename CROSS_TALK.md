# Cross-Talk entre sesiones de OpenCode Desktop

Documento de referencia para que cualquier agente de este proyecto pueda
comunicarse con otros chats/sesiones abiertos en el mismo proyecto.

> **Versión actual: v1.6.1 (2026-08-11).** Correcciones de semántica tras
> revisión externa (external-reviewer + 4 asesores + external-reviewer) sobre el protocolo anti-sueño
> v1.6 (sección 12): sobre de mensaje estándar con `msg_id`, outbox durable,
> ACK en frontera de turno (ventana de decisión 120s, sin backoff), presencia
> pasiva, lease con sucesor, escalada, DLQ, idempotencia (at-least-once +
> dedupe con estado CLAIMED), circuit breaker A/B/C y scan de recuperación
> RETRY/RESUME/RECONCILE/QUARANTINE con diagnóstico por log del servidor.
> v1.6.1 aclara identidades (task_id/run_id/msg_id/attempt/session_id), separa
> RESUME (`sigue`) de RETRY, añade AVISO-SPOF (detección pasiva del SPOF del
> líder, sin reelección), NACK explícito (7.5), handshake de protocolo
> (ACK-PROTOCOLO, 4d), idempotencia append-only con estado CLAIMED (12.8),
> flag en DLQ (12.7) y bloque canónico de reglas críticas (4f).
> Regla de oro: SIEMPRE `prompt_async` sin `noReply` para despertar (5.1, 12).
>
> El historial de versiones y descubrimientos está en **`CHANGELOG.md`**
> (v1.1 → v1.6.1), los pitfalls de Windows en **`CROSS_WINDOWS.md`**. Este
> archivo contiene SOLO las reglas vigentes.

## Contexto

OpenCode Desktop ejecuta un servidor HTTP local (`http://127.0.0.1:PUERTO`)
que expone la API de OpenCode. Cada chat abierto en la aplicación es una
**sesión** con un identificador único (`ses_...`). Cualquier agente con acceso
al shell (por ejemplo el agente `build`) puede usar esa API para:

1. Listar las sesiones del proyecto.
2. Leer los mensajes de una sesión.
3. **Enviar un mensaje a otra sesión** (con o sin esperar su respuesta).
4. **Verificar** que la otra sesión respondió (el mensaje queda en el historial).

La comunicación entre sesiones del mismo proyecto se hace directamente por
HTTP: no hace falta ningún complemento adicional, solo conocer el puerto del
servidor y las credenciales.

> **Procedimiento verificado** (pruebas reales del 2026-08-10): una sesión
> envió un mensaje a otra del mismo proyecto, la segunda leyó este documento,
> respondió de vuelta usando el mismo mecanismo, y el mensaje llegó y quedó
> persistido en la sesión de origen.

## 1. Detectar credenciales del servidor (AUTODETECCIÓN OBLIGATORIA)

> **REGLA (v1.4, consenso 2026-08-10):** autodetecta el puerto y toma el
> password del entorno **inmediatamente antes de CADA envío**, nunca de una
> tarea anterior y **nunca hardcodeados** en un script. Si un script tiene
> `$port = "56678"` (u otro valor fijo) o un password pegado literalmente,
> ese script está MAL: al reiniciar la aplicación el puerto cambia y el
> password se rota, y los mensajes enviados con valores viejos **no llegan**
> (se pierden en silencio o devuelven error). Cada modelo que envía mensajes
> es responsable de actualizar su snippet para autodetectarlo siempre.

Al reiniciar la aplicación cambia el puerto, y el password también puede
cambiar. **No reutilices credenciales de una tarea anterior ni las fijes en
un script**: detecta el puerto y el password en el momento del envío y
verifica que funcionan.

```powershell
$logDir = "$env:APPDATA\ai.opencode.desktop\logs"
$latestLog = Get-ChildItem $logDir | Sort-Object LastWriteTime -Descending | Select-Object -First 1
$content = Get-Content "$($latestLog.FullName)\main.log" -Raw
$port = ([regex]::Match($content, "server ready.*url: 'http://127\.0\.0\.1:(\d+)'")).Groups[1].Value
$password = $env:OPENCODE_SERVER_PASSWORD
Write-Host "Puerto: $port"
```

- Usuario de autenticación: `opencode`
- Password: normalmente `$env:OPENCODE_SERVER_PASSWORD` (la variable del
  proceso actual). También está guardado en `~/.config/opencode/.env`
  bajo la clave `OPENCODE_SERVER_PASSWORD`.
- Antes de continuar, verifica que las credenciales funcionan:

```powershell
curl.exe -s -m 8 -u "opencode:$password" "http://127.0.0.1:$port/global/health"
# Debe responder algo como: {"healthy":true,"version":"..."}
```

Si `health` no responde, la app se ha reiniciado: repite la detección desde cero.

## 2. Listar sesiones del proyecto

```powershell
curl.exe -s -u "opencode:$password" "http://127.0.0.1:$port/session" | ConvertFrom-Json
```

Cada sesión incluye `id`, `title`, `directory`, `agent`, `model` y `time`.
Filtra por `directory` para quedarte solo con las de este proyecto:

```powershell
$sessions = curl.exe -s -u "opencode:$password" "http://127.0.0.1:$port/session" | ConvertFrom-Json
$sessions | Where-Object { $_.directory -eq "TU_DIRECTIO_DEL_PROYECTO" } |
    Select-Object id, title, agent
```

## 3. Leer los mensajes de una sesión

```powershell
curl.exe -s -u "opencode:$password" "http://127.0.0.1:$port/session/<ID_SESION>/message?limit=20"
```

## 4. Enviar un mensaje a otra sesión

> **IMPORTANTE (pitfall probado):** el JSON debe ir en un archivo y enviarse
> con `--data-binary "@archivo"`. NO uses `-d '...'` inline en PowerShell:
> corrompe el JSON y el servidor responde `HTTP 500 Unexpected server error`.

> **Codificación:** envía los mensajes en ASCII plano (sin acentos ni
> caracteres especiales). Al leer respuestas, los acentos y las comillas
> tipográficas pueden llegar como signos `?` (mojibake); corrígelos al
> integrar el contenido.

> **Pitfall BOM (probado 2026-08-10):** si generas el archivo JSON con
> `[System.IO.File]::WriteAllText($f, $json, [System.Text.Encoding]::UTF8)`
> (o `Set-Content -Encoding utf8`), PowerShell escribe un **BOM** al inicio
> y el servidor responde `HTTP 500 Unexpected server error`
> (`err_82db6391`/`err_cb996c5b`). Debe ser UTF-8 **sin BOM**:
> `New-Object System.Text.UTF8Encoding($false)` — o directamente ASCII
> (sin acentos), que es lo que usa `send_message.ps1` (4e).
>
> **Preferir ASCII para el envío (v1.5, aporte model-c):** si el texto del
> mensaje puede contener caracteres no-ASCII (acentos, eñes, símbolos), es más
> seguro enviarlo en ASCII plano que en UTF-8 sin BOM: aun con UTF-8 sin BOM,
> caracteres como "í" o "ñ" pueden llegar como `?` (mojibake) en el destino.
> Escribe los mensajes sin acentos o reemplaza los caracteres problemáticos.
> Esto aplica a TODOS los envíos entre sesiones (líder→asesor y asesor→líder).

### 4a. Entregar mensaje sin que el agente destino procese (`noReply: true`)

El mensaje aparece al instante en el chat de la sesión destino como mensaje de
usuario, pero el agente destino NO responde. Útil para notas/avisos.

```powershell
$body = '{"parts":[{"type":"text","text":"TU MENSAJE"}],"noReply":true}'
$body | Set-Content "$env:TEMP\msg.json" -Encoding ascii -NoNewline

curl.exe -s -X POST -u "opencode:$password" -H "Content-Type: application/json" `
  --data-binary "@$env:TEMP\msg.json" `
  "http://127.0.0.1:$port/session/<ID_DESTINO>/message"
```

Devuelve `HTTP 200` con el mensaje creado.

### 4b. Enviar mensaje y esperar la respuesta del agente destino (síncrono)

Sin `noReply`, el agente de la sesión destino procesa el mensaje y su
respuesta completa (razonamiento + texto) se devuelve en la misma llamada.

```powershell
$body = '{"parts":[{"type":"text","text":"TU PREGUNTA"}]}'
$body | Set-Content "$env:TEMP\msg.json" -Encoding ascii -NoNewline

curl.exe -s -X POST -u "opencode:$password" -H "Content-Type: application/json" `
  --data-binary "@$env:TEMP\msg.json" `
  "http://127.0.0.1:$port/session/<ID_DESTINO>/message"
```

Esta llamada es síncrona: espera a que el agente destino termine de responder
(puede tardar más de 1 minuto).

### 4c. Enviar mensaje y dejar que el agente destino procese en segundo plano (método ESTÁNDAR para cross-talk)

`POST /session/:id/prompt_async` entrega el mensaje y devuelve `HTTP 204`
inmediatamente. El agente destino lo procesa en background y puede
responderte después. **Es el método estándar y preferido para toda la
comunicación entre agentes** (v1.5, aporte model-d): no bloquea, despierta al
destino y no necesita `noReply` (que es redundante — `prompt_async` ya entrega
sin esperar respuesta). Usa `noReply` (4a) o `/message` síncrono (4b) solo
cuando tengas una razón concreta.

```powershell
$body = '{"parts":[{"type":"text","text":"TU MENSAJE"}]}'
$body | Set-Content "$env:TEMP\msg.json" -Encoding ascii -NoNewline

curl.exe -s -X POST -u "opencode:$password" -H "Content-Type: application/json" `
  --data-binary "@$env:TEMP\msg.json" `
  "http://127.0.0.1:$port/session/<ID_DESTINO>/prompt_async"
```

### 4d. El líder comunica los IDs y el modelo a los integrantes (identidad/firma)

El **líder** (el que inicia la tarea) conoce su propio ID de sesión y los de
los demás: los autodetecta con `GET /session` (ver nota abajo). Para que cada
integrante firme sus tokens con SU ID y no se confunda, el líder debe
**incluir en el mensaje de la tarea el ID y el modelo de cada destinatario**,
indicándole explícitamente cuáles son los suyos:

```
[Tu ID de sesion es: <ID_DESTINO> y tu modelo es: <MODELO_DESTINO>.
Cuando respondas, firma tus tokens asi:
TOKEN:<ID_DESTINO>:<MODELO_DESTINO>
(por ejemplo ACUERDO-FINAL:ses_XXXXXXXX:model-b).
Tu token de respuesta sera: MEJORA-R1:<ID_DESTINO>:<MODELO_DESTINO>
(ejemplo: MEJORA-R1:ses_abc123:model-b).
El lider que te envia este mensaje es:
ID: <ID_LIDER> | modelo: <MODELO_LIDER>.
Responde SIEMPRE a esa sesion de origen.
PROTOCOLO: CROSS-TALK v1.6.1 — responde ACK-PROTOCOLO:1.6.1 si lo entiendes
]
```

**Handshake de versión de protocolo (v1.6.1, corrección external-reviewer 2026-08-11):** el
mensaje de la tarea incluye la línea `PROTOCOLO: CROSS-TALK v1.6.1`. El asesor
debe responder `ACK-PROTOCOLO:1.6.1` (tres segmentos EXACTOS: sin `v`, sin
prefijo) en los primeros 30 s, junto a su primer ACK si procede. Reglas:
- Si el asesor responde `ACK-PROTOCOLO:1.6.1` → versión compatible.
- Si responde `ACK-PROTOCOLO:<otra_versión>` → incompatibilidad: el líder le
  envía el **bloque canónico de reglas críticas (§4f)** y le aclara la
  diferencia de versión antes de proseguir.
- Si NO responde en 30 s → el líder lo asume como agente sin protocolo: le
  envía el bloque de reglas críticas (§4f) y reintenta el handshake.
- Un agente que no entienda el handshake también puede responder
  `NACK-PROTOCOLO:version_no_soportada:<versión_recibida>` (o con la versión
  que sí entiende); el líder decide si continuar con esa versión o excluirlo.
- Este handshake se repite al inicio de CADA tarea (no por mensaje).

Cada integrante recibe un mensaje individualizado con SU propio ID y SU modelo.
Así nadie adivina ni copia IDs ajenos.

> **El líder también se identifica (v1.5, probado 2026-08-10):** el mensaje del
> líder debe incluir su **propio ID y modelo** además de los del destinatario.
> Pitfall real: model-d quedó bloqueada al no saber a qué sesión debía responder
> porque el mensaje de la tarea no identificaba al emisor. Sin el ID del líder
> en el mensaje, el asesor no puede dirigir su respuesta (sección 5) ni firmar
> correctamente.

> **Firma con modelo legible (v1.2, 2026-08-10):** además del ID de sesión, la
> firma incluye el **nombre del modelo** (`TOKEN:<ID_SESION>:<MODELO>`). El
> usuario humano puede leer de un vistazo qué modelo envió cada mensaje, en vez
> de descifrar una cadena de letras y números. El ID de sesión se mantiene como
> identificador canónico (máquina); el modelo es legible (humano). El líder
> obtiene el modelo de `GET /session` → `model.id`.

> **Nota sobre autodetección del propio ID (líder):** el líder sabe su ID de
> sesión porque es la sesión que está ejecutando (p. ej. viene indicado en el
> contexto de la sesión actual). Los IDs de los demás los obtiene de
> `GET /session` filtrando por `directory`. Para una firma correcta, es
> imprescindible que el líder asigne a cada integrante SU ID real (el que
> aparece en la lista) y se lo comunique tal cual.

### 4e. Wrapper `send_message.ps1` (autodetección obligatoria, práctica anti-corrupción)

> **Consenso (Rondas de mejora 2026-08-10):** el wrapper es una **utilidad
> OPCIONAL** que encapsula el patrón "escribir JSON a archivo + `curl
> --data-binary`". No reemplaza el método manual documentado en 4a-4c: solo lo
> automatiza para evitar los pitfalls de quoting/encoding. Puedes usar el método
> manual o el wrapper indistintamente.
>
> **REGLA v1.4:** el wrapper **SIEMPRE autodetecta** el puerto desde el log más
> reciente y el password desde `$env:OPENCODE_SERVER_PASSWORD`, **ignorando**
> cualquier valor fijo pasado por parámetro. Es la versión recomendada para
> todo envío: elimina la clase de bug en la que un modelo usa credenciales
> viejas y su mensaje no llega.

`whiteboard/send_message.ps1` (ruta de referencia dentro del proyecto):

```powershell
param(
  [Parameter(Mandatory=$true)][string]$Destino,
  [Parameter(Mandatory=$true)][string]$Texto,
  [string]$Puerto,
  [string]$Password,
  [switch]$NoReply
)

# AUTODETECCIÓN SIEMPRE: el puerto cambia al reiniciar el servidor.
# Se ignora cualquier puerto/password pasado por parámetro.
$logDir = "$env:APPDATA\ai.opencode.desktop\logs"
$latestLog = Get-ChildItem $logDir | Sort-Object LastWriteTime -Descending | Select-Object -First 1
$Puerto = ([regex]::Match((Get-Content "$($latestLog.FullName)\main.log" -Raw),
  "server ready.*url: 'http://127\.0\.0\.1:(\d+)'")).Groups[1].Value
if (-not $Puerto) { throw "No se pudo autodetectar el puerto del servidor" }

$Password = $env:OPENCODE_SERVER_PASSWORD
if (-not $Password) { throw "No está definida OPENCODE_SERVER_PASSWORD en el entorno" }

$payload = @{ parts = @(@{ type = "text"; text = $Texto }) }
if ($NoReply) { $payload.noReply = $true }
$json = $payload | ConvertTo-Json -Depth 4
$file = Join-Path $env:TEMP "send_$(Get-Random).json"
[System.IO.File]::WriteAllText($file, $json, [System.Text.Encoding]::ASCII)
$endpoint = if ($NoReply) { "message" } else { "prompt_async" }
curl.exe -s -X POST -u "opencode:$Password" -H "Content-Type: application/json" `
  --data-binary "@$file" "http://127.0.0.1:$Puerto/session/$Destino/$endpoint"
Remove-Item $file -ErrorAction SilentlyContinue
```

Uso:

```powershell
& ".\whiteboard\send_message.ps1" -Destino "ses_AAAAAAAA" -Texto "TU MENSAJE" -NoReply
```

Notas:
- No hace falta pasar `-Puerto` ni `-Password`: se autodetectan siempre.
- `-NoReply` entrega sin que el destino procese (equivale a 4a).
- Sin `-NoReply` usa `prompt_async` (equivale a 4c).
- El wrapper usa `[System.IO.File]::WriteAllText` con codificación ASCII y
  `ConvertTo-Json`: evita los errores de `-NoNewline`/encoding que causan HTTP 500.
- Si autodetecta mal (p.ej. no encuentra el puerto) lanza error en lugar de
  enviar con credenciales obsoletas.

### 4f. Reglas críticas mínimas (handshake fallback, v1.6.1 O2 external-reviewer)

Cuando un asesor no responde `ACK-PROTOCOLO:1.6.1` en 30 s (4d), el líder le
envía este **bloque canónico** copiable, sin editarlo ni improvisar. Son 8
líneas suficientes para que cualquier agente opere sin haber leído
CROSS_TALK.md:

```
PROTOCOLO CROSS-TALK v1.6.1 — REGLAS CRITICAS:
1. Tu ID y modelo te los comunica el líder (no los adivines).
2. Responde SIEMPRE por API (prompt_async sin noReply) a la sesión del líder.
3. ACK primero, después procesas: ACK:<token>:<tu_ID>:<tu_modelo>.
4. Si NO puedes hacer la tarea: NACK:<token>:<tu_ID>:<tu_modelo>:<razon_cerrada>.
5. Antes de procesar: CLAIM tu msg_id en idempotencia-procesados.md.
6. Al terminar: marca PROCESADO en idempotencia-procesados.md.
7. Si recibes "sigue": es RESUME, continúa tu contexto (no es un nuevo mensaje).
8. Detalle completo en CROSS_TALK.md.
```

Con eso el handshake fallback es determinista: cualquier líder envía el mismo
texto y cualquier agente puede operar con lo mínimo.

## 5. Ejemplo completo: responder a una sesión que te escribió

> **REGLAS OBLIGATORIAS al recibir un mensaje de otra sesión:**
>
> 1. Tu respuesta debe **enviarse a la sesión de origen mediante esta API**
>    (`POST /session/<ID_ORIGEN>/message` o `prompt_async`). NUNCA te limites a
>    escribir la respuesta en tu propia conversación: el remitente no la ve.
>    **El canal principal es SIEMPRE la API.** Responder solo en tu chat es un
>    fallo de entrega: el emisor no recibe nada y debe reclamarte. Escribir en
>    el chat sin enviar por API solo se acepta cuando no existe otra forma de
>    enviar (fallo externo del entorno, el modelo no dispone de herramientas de
>    red, etc.) y SIEMPRE avisando por chat al líder de que no pudiste enviarlo.
> 2. Identifica al remitente por su **ID de sesión** (p. ej. `ses_AAAAAAAA`)
>    y el mensaje te dirá el token a devolver (p. ej. `ACUERDO-FINAL`).
>    Si el mensaje **no identifica al emisor** (ID + modelo), pide confirmación
>    o responde a la sesión de la que leíste el mensaje; el líder debe incluirlo
>    (sección 4d).
> 3. Si el mensaje pide una tarea/consulta, después de trabajarla responde con
>    **el MISMO token que recibiste** (si recibiste `BUGS-R1`, responde
>    `BUGS-R1:TU_ID:TU_MODELO`), **y tu resultado**, dirigido a la sesión que
>    preguntó. Usar otro token rompe la trazabilidad (v1.5, aporte model-c).
> 4. Ejecuta el script de esta sección, no "improvises" un texto suelto.

Si una sesión (por ejemplo `ses_AAAAAAAA`) te envía un mensaje, para
**responderle a esa sesión** ejecuta lo siguiente. Incluye un token único para
que la sesión de origen pueda verificar que tu respuesta llegó.

> **IMPORTANTE (identificar al emisor):** cuando la sesión de origen pide un
> token fijo (p. ej. `ACUERDO-FINAL-C1`), TODAS las respuestas llegan con el
> mismo token y no se puede saber quién la envió. Por eso, siempre que
> respondas, añade al token **tu propio ID de sesión y tu modelo** como sufijo,
> en el formato `TOKEN:TU_ID_DE_SESION:TU_MODELO`
> (p. ej. `ACUERDO-FINAL-C1:ses_XXXXXXXX:model-b`).
> Así la sesión de origen puede contar un voto por agente, saber exactamente
> quién acordó o propuso cambios, y mostrar al usuario humano qué modelo
> respondió.

> **CÓMO SABER TU PROPIO ID Y MODELO (NO los adivines):** tu ID y tu modelo son
> los que el líder te comunicó en el mensaje de la tarea (sección 4d). NUNCA
> intentes deducirlos filtrando la lista de sesiones por directorio: varios
> agentes comparten el mismo `directory` y es fácil confundirse (pitfall real:
> un asesor firmó con el ID de otro). Si el mensaje de la tarea no te los
> indica, responde a la sesión de origen con el token fijo SIN sufijo; el líder
> te identificará por el contenido.

```powershell
# 1. Detectar credenciales
$logDir = "$env:APPDATA\ai.opencode.desktop\logs"
$latestLog = Get-ChildItem $logDir | Sort-Object LastWriteTime -Descending | Select-Object -First 1
$content = Get-Content "$($latestLog.FullName)\main.log" -Raw
$port = ([regex]::Match($content, "server ready.*url: 'http://127\.0\.0\.1:(\d+)'")).Groups[1].Value
$password = $env:OPENCODE_SERVER_PASSWORD

# 2. Preparar la respuesta dirigida a la sesión que preguntó
$origen = "ses_AAAAAAAA"
# El líder te indicó tu ID y tu modelo en el mensaje de la tarea (sección 4d). Sustitúyelos:
$miSesion = "ses_XXXXXXXX"
$miModelo = "TU_MODELO"
$respuesta = "RESPUESTA AL OTRO AGENTE. Token de verificacion: MI-TOKEN-UNICO:$miSesion:$miModelo"
$body = @{ parts = @(@{ type = "text"; text = $respuesta }) } | ConvertTo-Json -Depth 5
$body | Set-Content "$env:TEMP\msg.json" -Encoding ascii -NoNewline

# 3. Enviarla a la sesión que preguntó (sin noReply para que ella lo vea al instante)
curl.exe -s -X POST -u "opencode:$password" -H "Content-Type: application/json" `
  --data-binary "@$env:TEMP\msg.json" `
  "http://127.0.0.1:$port/session/$origen/message"
```

Notas:
- Usa `noReply: true` si solo quieres entregar un aviso sin que el destino
  deba procesarlo.
- Usa `prompt_async` en el destino cuando la otra sesión debe procesar tu
  mensaje y trabajar en ello en segundo plano.
- **Pitfall verificado (2026-08-10):** un agente recibió una consulta, trabajó
  la respuesta y la escribió únicamente en SU conversación, sin enviarla a la
  sesión de origen. El remitente nunca la recibió y hubo que reclamarle. SIEMPRE
  completa la respuesta con el paso 3 de arriba: el `curl` que envía el mensaje
  a la sesión de origen.

## 5.1. Mecanismo de "despertado" (recibir sin hacer polling)

Cuando una sesión A envía un mensaje a una sesión B **sin `noReply`** (o con
`prompt_async`), el agente de B se "despierta" automáticamente y procesa el
mensaje en segundo plano: no hace falta que B esté haciendo polling. Así
funciona la cadena completa sin sondeos en el emisor:

1. El **líder** envía la tarea con `prompt_async` (sección 4c) a los asesores.
2. Cada **asesor** se despierta solo, trabaja la tarea y responde al líder
   usando la sección 5 (POST a la sesión del líder, también sin `noReply`).
3. El **líder** queda despierto de nuevo cuando llega la respuesta y puede
   procesarla sin haber sondeado el historial.

Lo que NO despierta al destino:
- `noReply: true` solo deja el mensaje en el chat; el agente no reacciona.
- Escribir la respuesta en tu propia conversación no se propaga a nadie.

Para terminar limpiamente un turno: entrega tu mensaje (con `prompt_async` o
POST sin `noReply`) y finaliza tu respuesta; el mensaje entrante te despertará
cuando llegue.

> **Pitfall verificado (2026-08-11, competición de acertijos):** durante la
> ronda 2, model-b/model-c respondieron al líder con `noReply: true`. El mensaje
> quedó guardado en la sesión del líder (`user` sin `time.completed`) pero el
> líder NO se despertó: el servidor nunca generó `message=process`/`stream`
> para su sesión. Confirmado por logs y por prueba controlada (dos mensajes
> idénticos a la misma sesión: `noReply: true` → sin respuesta; `noReply:
> false` → procesado y respondido). Los mensajes solo se vieron al revisar el
> historial manualmente. **Regla reforzada: para responder al líder, enviar
> SIEMPRE con `prompt_async` (sin `noReply`) o POST sin `noReply`. Nunca usar
> `noReply: true` para entregar una respuesta o resultado pendiente.**

Para terminar limpiamente un turno: entrega tu mensaje (con `prompt_async` o
POST sin `noReply`) y finaliza tu respuesta; el mensaje entrante te despertará
cuando llegue.

## 6. Verificar que la otra sesión respondió

Lee el historial de la sesión de origen filtrando los mensajes **nuevos de
tipo `user`** (son los que el otro agente inyecta) creados después de un
momento dado, y busca tu token:

```powershell
$mine = "ses_AAAAAAAA"   # la sesión donde esperas recibir la respuesta
$token = "MI-TOKEN-UNICO"  # puede incluir :ses_XXXXXX como sufijo del emisor

# Marca el momento justo antes de enviar tu mensaje
$start = [DateTimeOffset]::UtcNow.ToUnixTimeMilliseconds()

# Después de enviar el mensaje, sondea hasta 3 minutos:
$deadline = (Get-Date).AddMinutes(3)
while ((Get-Date) -lt $deadline) {
  $msgs = curl.exe -s -m 10 -u "opencode:$password" "http://127.0.0.1:$port/session/$mine/message?limit=10" | ConvertFrom-Json
  foreach ($m in $msgs) {
    if ($m.info.role -ne "user") { continue }
    if ($m.info.time.created -lt $start) { continue }
    foreach ($t in ($m.parts | Where-Object { $_.type -eq "text" } | ForEach-Object { $_.text })) {
      if ($t -like "*$token*") { Write-Host "RESPUESTA RECIBIDA: $t"; exit }
    }
  }
  Start-Sleep -Seconds 10
}
Write-Host "No se recibio respuesta en 3 minutos."
```

## 6.1. Diagnóstico de un asesor atascado / "sigue"

No esperes indefinidamente. Si pasada la ventana de verificación falta la
respuesta de algún asesor, **lee su sesión** para ver en qué punto se quedó y,
si sigue parado, **despiértalo enviándole `sigue`**. Estos son los pasos:

### a) Leer la sesión de un asesor (ver qué ha pasado)

```powershell
$asesor = "ses_AAAAAAAA"   # el ID de la sesión que no ha respondido

curl.exe -s -u "opencode:$password" "http://127.0.0.1:$port/session/$asesor/message?limit=10" |
    ConvertFrom-Json | ForEach-Object {
        $text = ($_.parts | Where-Object { $_.type -eq "text" } | ForEach-Object { $_.text }) -join ' '
        "[$($_.info.role)] ($($_.info.time.created)) $($text.Substring(0, [Math]::Min(200, $text.Length)))"
    }
```

Con esto puedes saber si:
- el mensaje de la tarea **le llegó** (último mensaje `user`),
- el agente **empezó a trabajar** (hay `reasoning` o un `assistant` a medias),
- **terminó y respondió** (último `assistant` dice "Enviado...") — si respondió
  pero no llegó a tu sesión, es el pitfall de la sección 5: reclamale que lo
  envíe por API,
- o simplemente **se quedó en blanco / sin actividad** (sin `assistant` tras el
  `user`): está atascado.

### b) Comprobar si el agente SIGUE trabajando (antes de intervenir)

Un asesor puede tardar más de 3 minutos simplemente porque **está trabajando
todavía** (responde bien y tarde), no porque esté atascado. Antes de enviarle
`cualquier cosa`, verifica que la sesión **ya no crece**:

- Lee su sesión (a) **dos veces separadas unos segundos** (p. ej. 15 s).
- Si entre las dos lecturas aparecieron **mensajes o partes nuevas**
  (nuevo `assistant`, `reasoning`, tool calls, o creció el texto del último
  mensaje), el agente sigue activo: **no le envíes `sigue`**, vuelve a esperar
  y repite la comprobación.
- Si las dos lecturas son **idénticas**, la sesión está quieta: ya puedes
  diagnosticar y, si procede, despertarlo con (c).

```powershell
$asesor = "ses_AAAAAAAA"
# Lectura 1
$a1 = curl.exe -s -u "opencode:$password" "http://127.0.0.1:$port/session/$asesor/message?limit=5" |
    ConvertFrom-Json
$a1Str = ($a1 | ForEach-Object { $_.info.id + ":" + ($_.parts | ForEach-Object { $_.type + ":" + $_.text }) }) -join '|'
Start-Sleep -Seconds 15
# Lectura 2
$a2 = curl.exe -s -u "opencode:$password" "http://127.0.0.1:$port/session/$asesor/message?limit=5" |
    ConvertFrom-Json
$a2Str = ($a2 | ForEach-Object { $_.info.id + ":" + ($_.parts | ForEach-Object { $_.type + ":" + $_.text }) }) -join '|'
if ($a1Str -eq $a2Str) { Write-Host "SESION QUIETA -> puede estar atascado" }
else                   { Write-Host "SESION CRECIENDO -> sigue trabajando, no intervenir" }
```

> Alternativa rápida: el resumen de la sesión también expone el tamaño
> (`GET /session` → `tokens` y `summary`). Si `tokens.output` o `summary`
> cambian entre lecturas, el agente está activo.

### c) Despertar al agente atascado con "sigue"

Solo tras confirmar en (b) que la sesión **no crece**, si el agente está
atascado o su respuesta quedó truncada, envíale `sigue` con `prompt_async`
para que retome su turno y complete el envío:

```powershell
$body = '{"parts":[{"type":"text","text":"sigue"}]}'
$body | Set-Content "$env:TEMP\msg.json" -Encoding ascii -NoNewline

curl.exe -s -X POST -u "opencode:$password" -H "Content-Type: application/json" `
  --data-binary "@$env:TEMP\msg.json" `
  "http://127.0.0.1:$port/session/$asesor/prompt_async"
```

> `sigue` sin `noReply` despierta al agente y le hace continuar su trabajo. Es
> una forma segura de reactivar un asesor parado sin perder su contexto. **No se
> envía si la sesión sigue creciendo (b): interrumpiría su trabajo.**
>
> **`sigue` es RESUME (v1.6.1, corrección revisión externa 2026-08-11):** NO es
> una retransmisión del mensaje lógico. `sigue` es una instrucción dirigida a la
> **sesión existente** para que continúe su contexto; NO lleva `msg_id` (ni
> `run_id`, ni `token`). Por tanto NO participa en la idempotencia de 12.8 ni en
> RECONCILE (12.10) a nivel de mensaje. Distinción de identidades (12.1):
> - **RESUME** (`sigue`): misma sesión + mismo contexto + `task_id` implícito
>   (la tarea en curso). El agente continúa donde estaba.
> - **RETRY**: retransmisión del MISMO mensaje lógico con el MISMO `msg_id`
>   (idempotente). Se usa SOLO en 12.10 (scan RETRY) cuando el paso es
>   idempotente y el mensaje puede reenviarse desde cero.
>
> **Pitfall probado (2026-08-10, tarea Buda):** un asesor atascado (model-e)
> se quedó parado DOS veces en la misma tarea, y tras un `sigue` se quedó de
> nuevo con un `assistant` vacío. La respuesta tardó ~1-2 min en completarse.
> Pauta: tras enviar `sigue`, vuelve a esperar y a comprobar (b). No envíes
> `sigue` en bucle rápido: espera ~30-60 s entre reintentos y verifica que la
> sesión está quieta otra vez antes de repetirlo. Un `sigue` nuevo mientras el
> agente aún está procesando (o ha encolado otro) puede confundir el turno.

> **Pitfall auto-continuación (probado 2026-08-10, tarea Bugs TXBridge):** el
> propio entorno inyecta mensajes automáticos tipo "Continue if you have next
> steps, or stop and ask for clarification" que **descarrilan** a algunos
> asesores: model-d los interpretó como "resume lo hecho" y respondió con un
> resumen (o preguntando si arreglaba bugs) en lugar de entregar su informe.
> Pauta: si un asesor responde "resumiendo" sin entregar la tarea, comprueba si
> hubo un mensaje automático de estos; envía un **nudge explícito y firme**
> (por ejemplo: "NO resumas ni arregles nada. Entrega YA el informe FINAL
> completo con firma `TOKEN:...`") con `prompt_async` (4c), y advierte que el
> mensaje automático "Continue..." debe ignorarse.

### d) Ventanas de espera (no esperes indefinidamente)

- **Contribuciones (ronda 1):** espera como máximo 3 minutos; si falta alguna,
  comprueba si el ausente sigue activo (b); solo si su sesión está quieta,
  envíale `sigue` (c).
- **Acuerdos finales:** mismo criterio, 3 minutos; los asesores suelen
  responder en segundos.
- **Regla de partición (v1.6.1, simplificación):** mensajes con ACK →
  **§12.3 gobierna completamente** (120s, decisión por dos señales, sin backoff).
  Mensajes sin ACK → **este apartado gobierna** (3 min). No hay que interpretar
  ambas reglas simultáneamente: el ACK es la frontera.
- **Antes de cualquier `sigue`:** verifica siempre que la sesión no crece entre
  dos lecturas (b). Si crece, espera y vuelve a comprobar.
- No reintentes la tarea completa: primero diagnostica (a) y comprueba (b).

### e) Monitoreo externo del líder y aviso desde el propio chat (v1.2)

> **Regla que TODO agente debe conocer (v1.2, 2026-08-10):**
>
> 1. **El agente que encarga la tarea (el líder) puede leer tu sesión desde
>    fuera** con `GET /session/<TU_ID>/message` (sección 6.1a) y consultar tu
>    estado con `GET /session/<TU_ID>` (sección 10.1). No tienes privacidad
>    frente al líder durante la tarea: si tu sesión queda quieta o vacía, lo
>    detectará.
> 2. **Si NO puedes completar la tarea** (proveedor caído, error, no sabes cómo
>    seguir), **escríbelo en tu propio chat** (tu conversación, mensaje normal,
>    sin comandos): el líder lo verá al leer tu sesión y te enviará ayuda
>    (instrucciones, script listo para copiar o un `sigue`).
> 3. **No intentes ejecutar comandos a ciegas** para "arreglar" un envío que
>    falla: si llevas varios intentos fallidos, detente y avisa en tu chat con
>    un texto plano (ver problema 11.6).
> 4. **Un `assistant` vacío** en tu sesión es la señal que el líder usa para
>    saber que algo falló: si tu respuesta está quedando vacía, acláralo en
>    texto dentro de tu propia conversación para no generar una racha de
>    mensajes vacíos.
> 5. **Si el problema es de CONECTIVIDAD** (no puedes enviar a la sesión del
>    líder, HTTP 5xx repetidos), escribe en tu chat el **error HTTP exacto**
>    (código y mensaje, p. ej. `HTTP 500 Unexpected server error`). El líder lo
>    usará para diagnosticar si el fallo es del servidor o del agente.

## 7. Confirmación de entrega (ACK)

> **Consenso (Rondas de mejora 2026-08-10):** para garantizar que un mensaje fue
> **procesado** (no solo recibido por el servidor), se usa un token ACK.
> El ACK complementa la verificación por ventana (sección 6): la ventana detecta
> la respuesta final; el ACK detecta el procesamiento inicial.

### 7.1. Formato del ACK

```
ACK:<token_original>:<ID_SESION_EMISORA>:<MODELO_EMISOR>
```

Ejemplo: si el líder envía la tarea con token `PROPUESTA-R1` y el asesor
`ses_BBBBBBBB` (modelo `model-b`) la procesa, el asesor envía:

```
ACK:PROPUESTA-R1:ses_BBBBBBBB:model-b
```

> **Aclaración (v1.3, consenso asesores 2026-08-10):** el ACK se construye sobre
> el **token completo recibido** (incluido su sufijo, si lo tenía) y añade al
> final el ID y el modelo **del emisor del ACK**:
> `ACK:<token_completo_recibido>:<ID_DEL_ACK>:<MODELO_DEL_ACK>`. El modelo va
> **siempre en último lugar**, separado por `:`. Así el emisor original sabe
> quién (qué modelo) le confirmó. El parsing debe tolerar 3 o 4 segmentos
> (`ACK:token:ID` sin modelo, o `ACK:token:ID:modelo`).

El modelo es opcional pero recomendado: hace legible para el usuario humano qué
modelo confirmó el procesamiento (sección 4d). El ID de sesión es el
identificador canónico para el conteo de votos.

### 7.2. Cuándo enviar el ACK

- El agente receptor envía el ACK como **primer paso** al procesar un mensaje de
  otra sesión, **antes** de su respuesta o contribución.
- El ACK se envía a la sesión del emisor usando `POST /session/<ID_ORIGEN>/message`
  (sección 5) o el wrapper `send_message.ps1` (4e), típicamente con `noReply: true`.
- El ACK confirma: *"recibí tu mensaje y lo estoy procesando"*.

### 7.3. Timeout y reintentos (lado del emisor)

Al enviar un mensaje que requiere confirmación:

1. Esperar máximo **30 segundos** por el ACK.
2. Si no llega, reintentar el envío del mensaje original.
3. Backoff exponencial: **30s, 60s, 120s** (3 reintentos máximo).
4. Tras 3 fallos, usar el mecanismo **`sigue`** (sección 6.1c) como fallback y
   registrar el fallo en `audit_log.md` (sección 9).

> **Precedencia v1.6 (2026-08-11):** este apartado describe el ACK clásico
> (v1.1). Para mensajes con `requiere_ack=true` en el protocolo anti-sueño, el
> plazo y la decisión los fija **§12.3**: 120 s FIJOS, SIN backoff — si la
> sesión crece, renovar lease y esperar (no es fallo); si está quieta, aplicar
> el circuit breaker (12.9). El backoff 30/60/120 de este apartado queda
> **sustituido** por §12.3 para esos mensajes; este apartado solo sigue
> aplicando a los reintentos del envío síncrono clásico (sección 4b) y a
> tareas sin `requiere_ack`.

### 7.4. Cuándo NO usar ACK

- En tareas simples de una sola respuesta (ej: "describe quién es Buda"), el ACK
  es opcional: la respuesta misma confirma el procesamiento.
- En tareas coordinadas con múltiples rondas, el ACK es **recomendado** para
  detectar atascos temprano.
- El emisor puede solicitar ACK explícitamente incluyendo `[ACK requerido]` en
  el mensaje. Si no se pide, el receptor no envía ACK.
- **Los mensajes `noReply` NO requieren ACK** (son *fire-and-forget*): solo las
  propuestas, acuerdos, cambios y reclamos exigen confirmación.

### 7.5. NACK explícito: el asesor NO puede hacer la tarea (v1.6.1, external-reviewer)

Un asesor que **no puede** procesar el mensaje lo declara con un NACK en lugar
de procesar a ciegas o quedarse en silencio. Es el canal canónico para fallos
por CAPACIDAD (no solo por conectividad, que se avisa en el propio chat, 6.1e):

```
NACK:<token_original>:<ID_SESION_EMISORA>:<MODELO_EMISOR>:<RAZON>
```

**Formato enriquecido (v1.7, corrección external-reviewer BUG A — trazabilidad del mensaje
rechazado):** el emisor del NACK puede añadir el `msg_id` y `run_id` originales
del sobre recibido (12.1), para que el líder correlacione sin ambigüedad:

```
NACK:<token_original>:<ID_SESION_EMISORA>:<MODELO_EMISOR>:<RAZON>:<msg_id>:<run_id>
```

El parser del motor (`Parse-CrossAckText`) detecta 6 segmentos y extrae
`msg_id`/`run_id`; los 4-5 segmentos siguen siendo válidos (superset, sin
breaking change).

**Razones cerradas (enumeración fija, sin texto libre — el líder las clasifica):**

| Razon | Significado |
|---|---|
| `CAPACITY` | No puedo completarlo (contexto agotado, tarea demasiado grande) |
| `TOOL_MISSING` | No tengo la herramienta/ruta/permiso que requiere la tarea |
| `AMBIGUOUS_TASK` | La tarea es ambigua y no puedo ejecutarla con seguridad |
| `PROVIDER_DOWN` | Mi proveedor/modelo está caído (fallo técnico, no de capacidad) |
| `OTHER` | Cualquier otra razón (aclarar en el mensaje o en el chat) |

Reglas:
- El NACK se envía por API a la sesión del emisor (igual que el ACK), con
  `noReply: true`, en cuanto se detecta la imposibilidad (no esperar el timeout).
- El emisor/leader recibe el NACK y decide según la razón (tabla abajo):
  **reasignar** a otro asesor (misma tarea, nuevo `msg_id` o mismo según 12.5),
  **abortar**, o **escalar al humano** (DLQ con `flag`, ver 12.7). Marca el
  outbox en consecuencia (`ESTADO=NACKED`).
- Un NACK no es un fallo del agente: es información operativa. No penalizar al
  emisor del NACK.
- El NACK también se usa en el handshake de protocolo (4d):
  `NACK-PROTOCOLO:version_no_soportada:<versión_recibida>`.

**Acción recomendada del líder por razón (v1.6.1, corrección external-reviewer F3):**

| NACK reason | Acción recomendada del líder |
|---|---|
| `CAPACITY` | Reasignar a otro asesor; si reasigna, NO incrementar `attempt` (no es una entrega nueva idempotente, 12.1) |
| `TOOL_MISSING` | Líder provee la ruta/herramienta en el reenvío (8.2) o reasigna a un asesor que la tenga |
| `AMBIGUOUS_TASK` | Líder reformula la tarea y reenvía con NUEVO `msg_id` (es nueva entrega, no RETRY) |
| `PROVIDER_DOWN` | No reasignar a otro proveedor inmediatamente; esperar (12.3, si la sesión crece) o excluir de esta ronda |
| `OTHER` | Reportar al humano en DLQ con `flag=HUMAN_REVIEW` |

### 7.6. Relación con el mecanismo existente

El ACK es complementario a la verificación por ventana (sección 6). La
verificación por ventana detecta la respuesta final; el ACK detecta el
procesamiento inicial. Usar ambos en tareas críticas; usar solo verificación por
ventana en tareas simples.

## 8. Protocolo de coordinación entre sesiones (tareas colaborativas)

Para tareas que ambas sesiones deben resolver y acordar:

1. **Propuesta:** envía tu borrador a la otra sesión con `prompt_async`,
   incluyendo un **token de ronda** único (p. ej. `PROPUESTA-R1`).
2. **Contribución:** si quieres que la otra sesión APORTE algo, díselo
   EXPLÍCITAMENTE en el mensaje (qué puede corregir, añadir o quitar). Si solo
   se le pide aceptar, tiende a responder "de acuerdo" sin trabajar.
3. **Respuesta:** la otra sesión te responde a TU sesión usando la sección 5,
   con el token y, si procede, su versión revisada. **Añade el ID de la sesión
   emisora al token** (`TOKEN:ses_XXXXXX`) para poder contar votos por agente.
   **Si no recibes su respuesta, no era una respuesta válida: reclamale que la
   envíe a tu sesión por API (sección 5), no que la escriba en su chat.**
4. **Integración:** integra su aporte, corrige el mojibake (`?`) si aparece,
   y envía la versión final pidiendo un token de acuerdo explícito
   (p. ej. `ACUERDO-FINAL`).
5. **Verificación:** sondea tu sesión (sección 6) hasta recibir el token de
   acuerdo o una contrapropuesta. Si tras 3 minutos falta algún asesor: lee su
   sesión (6.1a), comprueba que ya no crece (6.1b) y, solo entonces, envíale
   `sigue` (6.1c). No esperes ni reinicies sin diagnosticar.
6. Repite 1-5 hasta recibir el acuerdo explícito de ambas.

Los tokens hacen que la verificación sea inequívoca: filtran el ruido
(mensajes antiguos o duplicados) y confirman que la otra sesión llegó al
acuerdo. Ejemplo real verificado: propuesta → la otra sesión aportó 3 mejoras
→ integración → `ACUERDO-FINAL`.

### 8.1. Análisis de proyectos grandes (no agotes el contexto)

Cuando el código a analizar supera el contexto disponible (v1.5, aporte
model-c), NO intentes leer todos los archivos completos:

1. **Prioriza los archivos clave:** main/orquestador, headers públicos
   (`AudioEngine.h`, `AudioDevice.h`), y los módulos que concentran la lógica.
   Los `.cpp` grandes (p. ej. `ui/App.cpp`) se leen de forma selectiva por
   sección/offset según lo que busques.
2. **Usa herramientas de búsqueda** (Grep/Select-String, Glob) para localizar
   símbolos, call-sites y patrones en vez de leer archivos enteros.
3. **El líder debe indicar en el mensaje de la tarea los archivos prioritarios**
   y las líneas/rangos a revisar cuando los conozca (sección 4d), para que el
   asesor no malgaste contexto.
4. Si un archivo es enorme y solo afecta una zona, verifica la zona concreta y
   anota qué parte quedó sin revisar en vez de leerlo entero.

### 8.2. Localización de herramientas del entorno (pitfall probado: Python)

A veces los modelos no encuentran las herramientas o usan una ruta equivocada.
Pitfall real (2026-08-10): `python` en el PATH de este sistema es el **stub de
Windows Store** (`C:\WINDOWS\system32\python`) que NO ejecuta nada (devuelve
vacío en silencio). model-d no pudo usar Python hasta que el usuario humano le
indicó la ruta real. Por eso:

1. **Python real:** la ruta completa de tu instalación de Python (ver `where python` o `py -0p`)
   — NO usar `python` a secas ni `py`. Invocar siempre con la ruta completa.
2. **curl:** `C:\WINDOWS\system32\curl.exe` (funciona como `curl.exe`).
3. **git:** `C:\Program Files\Git\cmd\git.exe`.
4. **CMake:** `C:\Program Files\CMake\bin\cmake.exe`.
5. **GCC/G++ (MSYS2 UCRT64):** `C:\msys64\ucrt64\bin\g++.exe` / `gcc.exe`
   (toolchain real del build desktop; ver AGENTS.md del proyecto).
6. **Wrapper de envío:** `whiteboard\send_message.ps1` (autodetecta credenciales).

> Si el líder entrega una tarea que requiere una herramienta, debe indicar su
> **ruta completa** en el mensaje (sección 4d) y no asumir que el asesor la
> encontrará. Si un asesor no puede usar una herramienta, que lo avise por chat
> (6.1e) en vez de quedarse bloqueado o usar una ruta incorrecta.

## 9. Trazabilidad y auditoría (`audit_log.md`)

> **Consenso (Rondas de mejora 2026-08-10):** un único registro compartido da
> trazabilidad de quién dijo qué y cuándo. El nombre canónico es
> `whiteboard/audit_log.md` (una alternativa propuesta, `tracking.md`, quedó en
> minoría). Archivo *append-only*, uno por sesión de trabajo.

### 9.1. Formato de cada línea

```
| YYYY-MM-DD HH:MM:SS | ORIGEN | DESTINO | TOKEN | MODELO | TIPO | ESTADO | NOTA |
```

- **MODELO** (v1.3): modelo del emisor del mensaje (p. ej. `model-b`).
  Opcional: si no se conoce, dejar vacío.
- **TIPO** (válidos, v1.6.1 corrección external-reviewer F4): `PROPUESTA`, `ACUERDO`,
  `CAMBIO`, `RECLAMO`, `ACK`, `ACK-PROTOCOLO`, `NACK`, `NACK-PROTOCOLO`,
  `HEARTBEAT`, `REACTIVACION`, `ENV`, `REC`, `RESP`, `SIGUE`, `CLAIM`, `DONE`,
  `RELEASE`.
- **ESTADO** (válidos): `PENDIENTE`, `ENTREGADO`, `CONFIRMADO`, `FALLIDO`,
  `REINTENTANDO`.
- **NOTA**: máximo ~80 caracteres, sin acentos (ASCII plano).
- Separador: pipe `|`.

Ejemplo:

```
| 2026-08-10 15:30:12 | ses_AAAAAAAA | ses_BBBBBBBB | PROPUESTA-R1 | leader-model | ENV | ENTREGADO | Tarea: analisis workspace |
| 2026-08-10 15:30:18 | ses_BBBBBBBB | ses_AAAAAAAA | ACK:PROPUESTA-R1:ses_BBBBBBBB:model-b | model-b | ACK | CONFIRMADO | Recibido y procesando |
| 2026-08-10 15:31:45 | ses_BBBBBBBB | ses_AAAAAAAA | MEJORA-R1:ses_BBBBBBBB:model-b | model-b | RESP | ENTREGADO | 3 mejoras propuestas |
```

> **Firma con modelo (v1.2):** los tokens llevan el sufijo
> `:<MODELO>` además de `:<ID_SESION>` (sección 4d), para que el usuario humano
> lea el modelo de un vistazo. En el log, la columna MODELO lo hace explícito.

### 9.2. Regla

Cada agente registra sus envíos y recepciones en `audit_log.md`. No es un
requisito bloqueante, pero es la evidencia compartida para reconstruir el flujo
de propuestas y acuerdos si algo se pierde.

## 10. Monitoreo de sesiones y tareas

> **Consenso (Rondas de mejora 2026-08-10):** tres mecanismos complementarios,
> cada uno con un rol distinto:

| Mecanismo | Rol | Cuándo usarlo |
|---|---|---|
| `GET /session/:id` (API, ya existe) | Estado técnico en vivo (activa, metadatos, tokens) | Polling rápido de presencia |
| `whiteboard/task_status.md` | Tablero global de la tarea (en qué ronda va, quién respondió) | Actualizar por ronda, referencia para nuevos agentes |
| Ventana de verificación + doble lectura (6.1b) | Diagnóstico de atascos | Antes de enviar `sigue` |

### 10.1. Consulta rápida de estado con `GET /session/:id`

Verifica si una sesión está activa sin cargar el historial completo:

```powershell
curl.exe -s -u "opencode:$password" "http://127.0.0.1:$port/session/<ID_SESION>"
```

Retorna los metadatos de la sesión (`id`, `agent`, `model`, `time`, y si está
disponible `tokens`/`summary`). Es el método preferido de polling ligero
(1-2 s) en lugar de listar todas las sesiones y filtrar.

### 10.2. Tablero de estado de tareas (`task_status.md`)

Vista global para el líder y para agentes nuevos que se unan a mitad de tarea.
Se actualiza por ronda, no en tiempo real. Formato sugerido:

```
# Estado de la tarea <NOMBRE>
- Ronda: 2 de 5
- Asesores: model-b (R2 ok), model-d (R2 ok), model-c (R2 ok), model-f (proveedor caido)
- Pendiente: consenso final R3
```

> **Nota (consenso R3):** se eliminó el `heartbeat.json` propuesto en R1 por
> condiciones de carrera (varios agentes escribiendo el mismo archivo) y porque
> `GET /session/:id` ya cubre la presencia sin overhead.

## 11. Problemas conocidos y soluciones

> **Ampliado en v1.1** con los casos reales observados durante las rondas de
> mejora (2026-08-10). Los pitfalls específicos de PowerShell/Windows están
> consolidados en **`CROSS_WINDOWS.md`** (ex Apéndice B); aquí se conservan los
> ítems 1, 2, 7 y 8 por numeración histórica (referencias cruzadas) y se
> delega el detalle.

1. **JSON corrupto / HTTP 500** al usar `-d '...'` inline en PowerShell: usa
   archivo + `--data-binary` (sección 4) o el wrapper (4e). Detalle:
   `CROSS_WINDOWS.md` #1.
2. **Mojibake** (acentos como `?`): envía ASCII plano, corrige al integrar.
   Detalle: `CROSS_WINDOWS.md` #2.
3. **Agentes que responden solo en SU chat** sin enviar por API (sección 5):
   reclama el envío, no la redacción.
4. **Agentes atascados con `assistant` vacío:** verificar doble lectura (6.1b)
   y `sigue` (6.1c); no lanzar `sigue` en bucle (esperar ~30-60 s).
5. **Proveedor caído (no responde aunque se pida):** no es un atascamiento, es
   un fallo de proveedor. Detectable porque el último `assistant` queda **vacío**
   y creado **en milisegundos** tras el último `user` (un LLM no genera en
   milisegundos), y `time.updated` no avanza. Registrar el evento (ver
   `whiteboard/03_evento_north_mini.md`) y continuar con los agentes sanos.
6. **Agente que intenta comandos fallidos repetidos:** puede producir una racha
   de `assistant` vacíos. Leer su sesión, detectar la racha y enviarle **instrucción
   explícita con script listo para copiar** (como en el caso de model-d en R3).
7. **Rutas `/tmp/` en Windows:** no existen; usar `$env:TEMP`. Detalle:
   `CROSS_WINDOWS.md` #4.
8. **`&&` en PowerShell 5.1:** no existe; usar `;` o comandos separados.
   Detalle: `CROSS_WINDOWS.md` #5.
9. **Credenciales viejas hardcodeadas (v1.4, caso model-b):** un modelo envió su
   voto con `$port = "56678"` y un password pegado literalmente; el servidor se
   había reiniciado (puerto rotado a otro y password cambiado) y el mensaje
   **no llegó** aunque el script reportó éxito. Regla: autodetección obligatoria
   antes de CADA envío (sección 1) o usar el wrapper (4e), que ignora valores
   fijos. Verificar con `GET /global/health` tras detectar.

## 12. Protocolo anti-sueño (v1.6, con correcciones v1.6.1)

Objetivo: que NINGÚN mensaje quede dormido. Regla de oro heredada: SIEMPRE
`prompt_async` SIN `noReply` para despertar (sección 5.1). Los archivos son
RESCATE, no primario: la única primitiva que despierta al agente es
`prompt_async`.

### 12.1 Sobre de mensaje estándar

Todo mensaje del líder a un asesor (y entre asesores) lleva este prefijo:

    [msg_id=msg_<emisor_short>_<YYYYMMDD-HHMMSS-RAND6> | run_id=ACTIVIDAD |
     token=TOKEN_ESPERADO | requiere_ack=true|false |
     lease=ses_A@UTC+3min|sucesor=ses_B | timestamp=ISO8601]

**Identidades formales (v1.6.1, corrección revisión externa 2026-08-11):** el
protocolo distingue cinco identidades independientes. Una misma tarea puede
tener varios runs, varios mensajes y varios intentos; NO son intercambiables:

| Identidad | Significado | Ejemplo | Se usa en |
|---|---|---|---|
| `task_id` | La tarea lógica (un objetivo) | `TX-DSP-042` | resumen, DLQ, reportes |
| `run_id` | Una ejecución concreta de la tarea | `RUN-20260811-01` | sobre (correlación) |
| `msg_id` | Un mensaje lógico (idempotency key) | `msg_model-d_20260811-1512-a3f9` | outbox, 12.8, RETRY |
| `attempt` | nº de intentos de envío de ese msg | `attempt=2` | backoff, circuit breaker |
| `session_id` | La sesión de agente (proceso/contexto) | `ses_013b...` | enrutado, presencia |

**Semántica de `attempt` (v1.6.1, corrección revisión externa):** `attempt` es
el número de ENTREGAS del mensaje lógico (`msg_id`). Reglas:
- **RETRY** → `attempt + 1` (es una nueva entrega del mismo `msg_id`).
- **TRANSFER** (lease a sucesor) → `attempt + 1` (nueva entrega, aunque cambie
  la `session_id`).
- **RESUME** (`sigue`) → NO incrementa `attempt` (no es una entrega nueva: la
  sesión ya tenía el mensaje y solo continúa su contexto).
- `max_saltos=2` (12.5) y el circuit breaker A/B/C (12.9) leen este contador.

- `msg_id`: ÚNICO por mensaje lógico. Incluye prefijo de la sesión emisora
  (`msg_model-d_...`) para garantizar unicidad sin coordinación (ajuste model-d,
  R3). Sirve de idempotency key, event_id y referencia en los archivos.
- `run_id`: actividad actual (p. ej. `MEJORA-V16-R1`) para correlacionar.
- `token`: lo que el asesor debe devolver firmado (`TOKEN:...:ID:MODELO`).
- `requiere_ack`: `true` en tareas críticas; `false` en tareas simples
  (regla 7.4).
- `lease`: dueño + deadline UTC + **sucesor explícito** (no solo dueño y
  deadline), para que el sobre sea autocontenido (ajuste model-a, R3).

> **NOTA de identidades (v1.6.1):** `sigue`/RESUME opera sobre `session_id` +
  `task_id` (continúa el contexto). `RETRY`/RECONCILE/TRANSFER operan sobre
  `msg_id` (retransmiten o reconcilian el mensaje lógico). No mezclarlas:
  enviar `sigue` no es retransmitir, y retransmitir sin contexto no reanuda.

### 12.2 Outbox durable (ANTES de enviar)

Antes de llamar a `prompt_async`, el **emisor** escribe una línea en
`whiteboard/outbox.md` (append-only):

    [2026-08-11T15:42:03Z] OUTBOX | msg_id | dest=ses_X | run_id | token |
    lease=ses_A@UTC+3min|sucesor=ses_B | ESTADO=EN_VUELO

El ACK (12.3) o el resultado pasan la línea a `ESTADO=CONFIRMADO`. Si expira
sin confirmar: `ESTADO=EXPIRADO`. Si se transfiere el lease: `ESTADO=TRANSFERIDO`.
**Solo el emisor actualiza el outbox** (conoce el estado del ACK/timeout);
el receptor solo envía ACK y procesa, no escribe en el outbox (evita carreras
por escritura concurrente, ajuste model-d R3). El líder lee el outbox, no
adivina desde el chat. Sobrevive reinicios.

> **POR QUÉ SOLO EL EMISOR (verificado por test T10, 2026-08-11):**
> `Add-Content` de PowerShell es ATOMICO (todo-o-nada; nunca intercala ni
> corrompe una línea) pero usa BLOQUEO EXCLUSIVO por llamada. Con dos
> procesos escribiendo a la vez, el segundo recibe `IOException` ("archivo
> en uso por otro proceso") y PIERDE su línea silenciosamente si no la
> reintenta. En el test, W1 perdió las 25 líneas frente a W2 (0 corruptas).
> Conclusión: la exclusividad del emisor no es una preferencia, es un
> requisito de integridad. Si algún día se necesitara escritura concurrente
> real, hacer append con reintento con backoff ante IOException (o usar un
> archivo de lock).

### 12.3 ACK en frontera de turno (requiere_ack=true)

Al despertar y procesar un mensaje con `requiere_ack=true`, el asesor responde
PRIMERO con el formato completo de la sección 7.1:
`ACK:<token_recibido>:<ID_AS_ASESOR>:<MODELO>`. El ACK significa "recibido y
comenzando a procesar", no "terminé" (ajuste model-d R3). Es asíncrono y no
bloqueante: el asesor continúa trabajando tras emitirlo.

Si el líder no recibe ACK en **120s** (ajuste model-d R3; 60s era insuficiente
para tareas con investigación previa como leer noticias y escribir visión),
**NO incrementa el plazo**: decide por DOS señales (12.4/12.9). Término
preciso: es una **"ACK decision window" de 120s** (ventana de decisión), no un
timeout: si la sesión crece, se espera otra ventana en lugar de declarar fallo.

1. ¿La sesión crece? (12.4a). Si el modelo está generando (p. ej. timeout
   de proveedor con retry automático, caso 524 observado en 2026-08-11:
   ACK válido a los 323s tras error [504]→retry): renovar lease y esperar
   OTRO ciclo; el ACK llegará. Esto NO cuenta como fallo de escalada.
2. ¿Sesión quieta Y sin ACK? → dormido/muerto → circuit breaker (12.9):
   A transitorio → 1 retry idempotente; B recuperable → renovar lease;
   C permanente → escalada (12.6) → DLQ (12.7).

Regla de finitud: nunca más de 2 ciclos de retry al mismo destino (12.9).
La espera total queda acotada (plazo fijo x 2 ciclos); el ACK tardío por
proveedor lento se tolera SOLO si la sesión crece. Un modelo que nunca
contesta se detecta por sesión quieta, no por "timeout cada vez más largo".

### 12.4 Presencia pasiva (sustituye al heartbeat PING/PONG)

Sin mensajes PING/PONG (ruido; consenso R2). El líder comprueba presencia con
dos lecturas de `GET /session/:id` separadas (6.1b) y/o mirando
`whiteboard/outbox.md`: si un `EN_VUELO` expira y la sesión NO crece →
dormido. Si crece → renovar lease y esperar.

### 12.5 Lease con sucesor (la tarea nunca queda sin dueño)

Cada tarea en el outbox lleva lease: dueño + deadline (UTC+3min) + sucesor.
**Sucesor por defecto = siguiente en la secuencia de turnos**, no siempre el
líder (ajuste model-d R3: distribuye la carga de handoffs; el líder sigue
disponible como sucesor explícito si se designa). Reglas:

- (a) lease expirado y `EN_VUELO`: comprobar si la sesión crece (6.1b).
  Si crece, renovar lease y esperar.
- (b) Si está quieta: RETRY idempotente (retransmitir el MISMO `msg_id`,
  no un `sigue`; ver distinción RESUME/RETRY en 6.1c y 12.1).
- (c) Si tras el retry sigue `EN_VUELO`: REASIGNAR al sucesor con
  `prompt_async`, mismo `msg_id` y nota "lease transferido". `max_saltos=2`.
- (d) Agotado: QUARANTINE → DLQ con reporte humano.

### 12.6 Canal de escalada (whiteboard/escalated.md)

Si `prompt_async` falla 3 veces, se escribe una entrada en
`whiteboard/escalated.md` (unifica escalated + wake-on-write, consenso R2):

    URGENTE | para=<ses_ID> | msg_id | run_id | de=<ses_emisor> |
    expira=UTC | "resumen"

El asesor verifica `escalated.md` al despertar (tras cualquier `prompt_async`)
y tras cada turno; si hay entrada para él, la procesa y marca `RECIBIDO`.
NOTA: el archivo NO despierta por sí solo; es respaldo para cuando el agente
ya está despierto por otro medio. "Magic packet" a nivel de aplicación
(Wake-on-LAN).

> **Patrón de coordinación de CROSS: wake-on-write estigmergico (v1.6.1,
> consenso asesores 2026-08-11).** Este mecanismo — archivo compartido como
> canal de coordinación, con escritura como señal y mensajes `URGENTE|para=<ID>`
> parseables que cada agente comprueba al despertar y tras cada turno — es el
> **patrón de coordinación por estado compartido desarrollado para CROSS**. La
> coordinación estigmergica (señales en un espacio compartido descubiertas por
> otros agentes) existe en la literatura; CROSS la aplica de una forma
> particular sobre archivos markdown con la semántica `URGENTE|para=<ID>`
> descrita aquí. No se afirma equivalencia ni ausencia de equivalente en otros
> protocolos (A2A, MCP, ACP/ANP): se documenta como patrón propio del proyecto,
> con la analogía del "magic packet" de Wake-on-LAN (patente WO2007024306A1) —
> binario, unidireccional y solo despierta, mientras que el nuestro es legible
> por humanos, bidireccional (cualquier agente escribe y lee) y además de
> despertar transporta el mensaje y su `msg_id` (idempotencia).

### 12.7 DLQ (whiteboard/dlq-mensajes.md)

Tras agotar la escalada, el mensaje se escribe en `whiteboard/dlq-mensajes.md`
(append-only, visible a todas las sesiones y al humano):

    [fecha] DLQ | msg_id | para=ses_X | de=ses_Y | reintentos=3 |
    ESTADO=SIN RECOGER | flag=HUMAN_REVIEW | "resumen"

El campo `flag` es **cerrado** (parseable, v1.6.1 corrección external-reviewer F2):
`HUMAN_REVIEW | NACK_ORIGINATED | QUARANTINE | PROVIDER_DOWN`. Facilita el
filtrado para el humano; el `"resumen"` queda libre para el detalle.

El destinatario lo marca `RECIBIDO` al recogerlo. Nada se pierde
silenciosamente.

### 12.8 Idempotencia (whiteboard/idempotencia-procesados.md)

**Máquina de estados (v1.6.1, correcciones external-reviewer 2026-08-11 + F1-F4/O1):** cada
`msg_id` pasa por los estados `CLAIMED` → `PROCESADO`. El estado `CLAIMED`
cubre la ventana entre "comprobar que no existe" y "terminar de procesar" (que
en un LLM dura 30-90 s), evitando la race condition de doble procesamiento:

    msg_id | timestamp_claim | modelo_claimer | CLAIMED_BY=ses_X
    msg_id | timestamp | modelo | PROCESADO
    msg_id | timestamp | modelo | SUPERSEDED_BY=ses_Y

**Append-only (v1.6.1, O1 external-reviewer):** el fichero es un log append-only (como el
outbox), NO editable in-place. La edición de una línea existente en PowerShell
(`Get-Content` → modificar en memoria → `Set-Content`) NO es atómica y crea
una race cuando dos agentes escriben a la vez (p. ej. el claimer legítimo
escribiendo `PROCESADO` mientras el líder hace release). Por eso:

- **CLAIM**: antes de procesar, el receptor ANEXA
  `msg_id | timestamp_claim | modelo_claimer | CLAIMED_BY=ses_X` (formato
  EXACTO, sin espacios extra ni variaciones — el parser del CLI lo reconoce).
  Si la última línea del `msg_id` ya es `CLAIMED` o `PROCESADO` vigente →
  salta (duplicado).
- **PROCESADO**: NO se reescribe la línea CLAIMED: al terminar, el receptor
  ANEXA una línea nueva `msg_id | timestamp | modelo | PROCESADO`.
- **Release (abortar)**: NO se elimina la línea: si el claimer aborta la
  tarea, ANEXA `msg_id | timestamp | modelo | SUPERSEDED_BY=ses_Y` (el
  reclamante original u otro agente declara que la reclamación queda sin
  efecto; no escribe `PROCESADO`).
- **Retry con CLAIMED (v1.6.1):** un RETRY solo se dispara si el `msg_id` NO
  tiene línea alguna en el fichero, o si su última línea es `CLAIMED_BY=ses_X`
  Y la sesión `ses_X` está quieta (12.4, doble lectura). Si `ses_X` crece →
  esperar: el claimer sigue procesando. Esto replica el lease a nivel de
  receptor.
- El parser del CLI lee la **ÚLTIMA línea** de cada `msg_id` y esa determina
  el estado vigente (`CLAIMED_BY=ses_X`, `PROCESADO` o `SUPERSEDED_BY=ses_Y`).
  Las líneas anteriores son historial del ciclo de vida del `msg_id`.

Entrega **at-least-once con deduplicación por `msg_id`**: el envío puede
repetirse (reintentos, retransmisiones), pero el receptor procesa cada `msg_id`
una sola vez.

**Alcance del effectively-once (v1.6.1, corrección revisión externa):** la
deduplicación por `msg_id` da comportamiento effectively-once SOLO para
operaciones idempotentes (un segundo procesamiento no produce efecto distinto).
Para operaciones NO idempotentes (p. ej. el receptor modifica un archivo y
muere ANTES de anexar `PROCESADO`), la retransmisión procesaría dos veces:
por tanto se requiere **RECONCILE (12.10)** — verificar el archivo de salida o
el efecto antes de retransmitir — o confirmación del efecto. No se afirma
effectively-once universal "por construcción" (eso solo sería garantizable con
coordinación distribuida que aquí no existe).

### 12.9 Circuit breaker A/B/C (max 2 intentos)

Antes de enviar "sigue", clasificar el fallo:

- A (transitorio): timeout/reintento puntual → RETRY idempotente (1 vez).
- B (recuperable): sesión crece pero lenta → renovar lease, esperar.
- C (permanente): no crece / error estable → REASIGNAR sucesor o QUARANTINE.

Nunca más de 2 intentos ciegos al mismo destino.

**Parámetros por defecto (implementados en `cross-delivery.psm1`,
`cross.config.json`):**

| Parámetro | Valor | Dónde |
|---|---|---|
| Intentos máximos (`MaxAttempts`) | 2 (`max_retries`) | config |
| Timeout de espera de ACK | 120 s (`default_ack_timeout_s`) | config / `--ack-timeout` |
| Backoff entre reintentos | 2 s lineales (`retry_backoff_s × intento`) | config |
| Lease | 3 min (`default_lease_minutes`), renovado 1× por intento si el destino crece | config |
| Verificación de "crece" | 15 s (`session_growing_check_ms`), 2 fingerprints de mensajes | config |
| Polling de ACK | cada 3 s hasta deadline | motor |
| HTTP reintentables | 0 (red/timeout), 408, 429, ≥500 | motor |
| HTTP sin retry | 404 → `DEST_NOT_FOUND`/EXPIRADO; 401/403 → `AUTH_FAILED`/EXPIRADO | motor |

**reason_code NACK (v1.7, corrección external-reviewer):** `NACK_TIMEOUT` (0/408/ACK_TIMEOUT),
`NACK_RATE_LIMITED` (429), `NACK_DEST_NOT_FOUND` (404), `NACK_CONFIG_ERROR`
(401/403), `NACK_SERVER_ERROR` (5xx agotado), `NACK_HTTP_4XX` (otro 4xx),
`NACK_NETWORK` (default). La cuenta de `attempt` se **persiste en la línea del
outbox** (`attempt=N`) antes de cada envío (corrección external-reviewer BUG L): tras un crash
del proceso, `cross send` retoma desde el intento ya realizado.

Transiciones de estado del motor de entrega:
`EN_VUELO → CONFIRMADO` (ACK o `--no-wait`/sin ACK requerido), `→ NACKED`
(NACK con razón), `→ EXPIRADO` (404/401/403, HTTP no reintentable agotado, o
sin ACK tras max intentos → `ACK_TIMEOUT`). El scan (12.10) gestiona los
`EXPIRADO`/`EN_VUELO` vencidos con la escalera (12.11).

### 12.10 Scan de recuperación (RETRY/RESUME/RECONCILE/QUARANTINE)

El líder escanea el outbox al cerrar cada ronda Y automáticamente al detectar
`EN_VUELO` expirado (el scan dispara el circuit breaker, no al revés; ajuste
model-d R3). Clasifica cada mensaje expirado:

- **RETRY**: solo si el paso es idempotente (msg_id), mismo prompt y token.
- **RESUME**: si el agente dejó checkpoint parcial en whiteboard (continuar,
  no repetir). **Cómo se ejecuta (v1.6.1):** RESUME no retransmite el mensaje
  original ni reusa su `msg_id`; el líder envía `prompt_async` sobre la MISMA
  `session_id` con una instrucción de continuación basada en el checkpoint
  existente (p. ej. `"Continúa desde <archivo>:<línea>. Entrega el informe
  final firmado"`). Quién determina el punto de continuación: el líder, leyendo
  el checkpoint del whiteboard. Es la primitiva `sigue` de 6.1c.
- **RECONCILE**: si el efecto pudo ocurrir pero falta el receipt: el líder
  inspecciona la sesión y/o el **archivo de salida** (p. ej.
  `diario/15_charla_conciencia.md`, `whiteboard/16_diario_conversaciones.md`)
  ANTES de decidir;
  si el trabajo está registrado allí, marcar CONFIRMADO sin reenviar (evita
  duplicados, ajuste model-d R3).
- **DIAGNÓSTICO POR LOG DEL SERVIDOR** (último recurso antes de QUARANTINE,
  caso 524/2026-08-11): si la sesión está quieta Y no hay ACK tras los
  reintentos, el líder lee el log del servidor (`%USERPROFILE%\.local\share\
  opencode\log\opencode.log`, timestamps en UTC) buscando el `session.id`
  del asesor en el intervalo del timeout. Clasifica el fallo:
  - `stream error ... [504]/[524]` o `connect timeout` / `ENOTFOUND` /
    `Rate limit exceeded` → **fallo del PROVEEDOR, agente sano**: el servidor
    reintenta solo; NO escalar, renovar lease y esperar (el ACK suele llegar).
  - `exiting loop` normal / sin error en el intervalo → **agente dormido o
    muerto de verdad**: seguir la escalada normal (12.6 → DLQ).
  - `stream error` distinto (auth, modelo inexistente) → error de
    configuración: reportar al humano en DLQ.
  Este paso evita falsos QUARANTINE por intermitencia del proveedor
  (observado: ACK válido a los 323 s tras error 524 con retry automático).
- **QUARANTINE**: si no se puede probar seguridad → DLQ con reporte humano.

NUNCA reenviar a ciegas un paso no idempotente que pudo haber mutado estado.

### 12.11 Escalera completa (orden de gestión)

Sobre (12.1) → Outbox (12.2) → ACK (12.3) → Presencia pasiva (12.4) →
Circuit breaker (12.9) → Lease+sucesor (12.5) → Scan (12.10, incluido
diagnóstico por log del servidor) → Escalada (12.6) → DLQ (12.7).
Idempotencia (12.8) transversal. La escalada y la DLQ son las últimas
etapas del circuit breaker (C = permanente → escalada → DLQ).

### 12.12 Archivos usados por v1.6 (todos en whiteboard/)

- `outbox.md`: registro de envíos ANTES de enviar (EN_VUELO/CONFIRMADO/
  EXPIRADO/TRANSFERIDO/NACKED).
- `escalated.md`: canal de escalada `URGENTE|para=<ID>`.
- `dlq-mensajes.md`: mensajes no entregados (SIN RECOGER/RECIBIDO, flag).
- `idempotencia-procesados.md`: log append-only del ciclo de vida de cada
  msg_id (CLAIMED → PROCESADO / SUPERSEDED_BY); dedupe por última línea.

### 12.13 Trade-offs aceptados (documentado tras revisión externa, 2026-08-11)

- **SPOF del líder (aceptado):** el líder (sesión que coordina) es un punto
  único de fallo: es quien escanea el outbox (12.10), ejecuta la escalera
  (12.11) y decide QUARANTINE/DLQ. Si el líder se duerme o se cierra, los
  mensajes `EN_VUELO` quedan sin gestionar hasta que otra sesión o el humano
  los recupere. **No hay elección/reelección automática de líder en v1.6/v1.6.1.**
  Mitigación en v1.6.1 (consenso asesores 2026-08-11, sin reelección):
  **AVISO-SPOF (detección pasiva por asesores).** Cada asesor, al final de su
  turno (y al despertar), escanea el outbox de forma ligera:
  `Get-Content whiteboard/outbox.md | Where-Object { $_ -match "EN_VUELO" }`.
  Si encuentra un `EN_VUELO` vencido (timestamp +3 min) cuyo `para=` coincide
  con SU propio ID y su sesión está quieta (6.1b), escribe en
  `whiteboard/escalated.md`:
  `AVISO-SPOF | msg_id=<ID> | para=<ses_ID> | de=<su_ID> | expira=UTC | "EN_VUELO vencido, sesion quieta"`.
  Si el `EN_VUELO` ajeno NO es suyo, puede enviar al líder un mensaje (sin
  `noReply`) "hay un mensaje caído" (visibilidad temprana, propuesta model-c),
  o escribirlo en su propio chat (6.1e) si no puede enviar. Esto NO toma la
  tarea ni reemplaza al líder: solo da visibilidad temprana y deja la gestión
  al líder (o al humano vía `outbox.md`/`dlq-mensajes.md`). Añadir elección de
  líder o heartbeats del líder sigue siendo mejora futura (Apéndice A).
- **Entrega at-least-once (aceptado):** la deduplicación por `msg_id` evita
  procesamiento duplicado, pero no garantiza "exactly-once" en el sentido
  estricto de sistemas distribuidos (no hay transacción atómica entre el
  efecto y su registro). El mecanismo proporciona **at-least-once con
  deduplicación; effectively-once solo cuando la operación es idempotente o el
  efecto se reconcilia antes de retransmitir** (12.8/12.10).
- **Archivos = respaldo visible, no canal primario:** la única primitiva que
  despierta a un agente dormido es `prompt_async` (12.1/5.1). Los archivos
  (outbox, escalated, DLQ) son el registro durable y el canal de escalada,
  no reemplazan el wakeup. Asumido desde v1.6.

### 12.14 Diagnóstico unificado (`cross poll/status/reconcile/aviso-spof`, Fase 4a)

Implementado en `cross/modules/cross-diagnostic.psm1` (2026-08-12). Los 4
subcomandos SON LECTURA: no mutan outbox (solo `poll` puede marcar `NACKED` si
detecta un NACK en `audit_log.md` no reflejado, y `aviso-spof --apply` anexa a
`escalated.md`). Comandos:

- **`cross poll --msg msg_X [--timeout S] [--interval MS]`:** diagnostica un
  mensaje del outbox usando la señal primaria `session.status` + heurística de
  crecimiento (12.4/12.9). Bucle hasta deadline (por defecto
  `default_ack_timeout_s`) o diagnóstico terminal. Tabla de decisión:

  | outbox | sesión | diagnóstico | acción |
  |---|---|---|---|
  | CONFIRMADO / audit ACK | — | `ACKED` | ninguna |
  | NACKED / audit NACK | — | `NACKED` | gestionar por razón (7.5/12.10) |
  | EXPIRADO/TRANSFERIDO/QUARANTINE | — | `TERMINAL` | escalera (12.10/12.11) |
  | EN_VUELO | lease vencido | `EXPIRED` | scan (12.10) |
  | EN_VUELO | `busy` + crece | `WORKING` | esperar (renovar lease 12.4a) |
  | EN_VUELO | `busy` + quieta | `ACKED_QUIETA` | investigar audit/outbox |
  | EN_VUELO | `idle` + quieta | `QUIETA_SIN_ACK` | circuit breaker 12.9 → escalar |
  | EN_VUELO | `error` | `PROVIDER_DOWN` | renovar lease y esperar |
  | EN_VUELO | no verificable | `UNKNOWN` | revisar puerto/servidor |

- **`cross status [--msg|--run-id|--agent]`:** resumen del estado: outbox por
  estado y por agente (con estado de sesión), `expired_unmanaged` (EN_VUELO con
  lease vencido), idempotencia por estado, `claimed_orphaned` (CLAIMED_BY de
  sesión quieta), `escalated_pending` (URGENTE sin RECIBIDO), `aviso_spof`,
  `dlq_unread`/`by_flag`. Con `--msg`, añade `lifecycle` (outbox + idempotencia
  + audit_log para ese msg_id).
- **`cross reconcile --msg msg_X --check-file PATH [--expected-token T]`:**
  verifica si un entregable llegó al destino buscando su token en el archivo de
  salida. Veredictos: `CONFIRMED` (token en check-file → `mark_confirmed`),
  `AMBIGUOUS` (check existe pero sin token → `investigate`), `NOT_FOUND`
  (check inexistente → `retry`). Implementa el paso RECONCILE de 12.10.
- **`cross aviso-spof [--apply] [--for ses_X]`:** implementa la mitigación
  SPOF de 12.13. Escanea los `EN_VUELO` vencidos: si `dest` es mi sesión y está
  quieta, anexa `AVISO-SPOF` a `escalated.md` (solo con `--apply`); si es de
  otra sesión, avisa al líder (sin `--apply` es dry-run, no escribe ni envía).
   El aviso al líder va a `lider_session_id` de `cross.config.json` (fallback a
   mi propia sesión si no está definido).

### 12.15 Acciones operativas (`cross ack/nack/resume/restart-task/nudge/escalate/dlq/quarantine/diagnose`, Fase 4b)

Implementado en `cross/modules/cross-action.psm1` (2026-08-13). Complementan la
capa de LECTURA de 12.14 con las acciones que el líder ejecuta según 7.5 y
12.10/12.11: SÍ mutan outbox, escalated, DLQ y audit. Comandos:

- **`cross ack --token T --for-msg-id X [--to ses_Y] [--model M]`:** emite
  `ACK:<token>:<ID_SESION_EMISORA>[:<MODELO>]` (3-4 segmentos, 7.1) al destino y
  registra `ACK|ENVIADO` en `audit_log.md`. `--to` por defecto = mi sesión.
- **`cross nack --token T --for-msg-id X --reason R [--note] [--for-run-id R]
  [--to] [--model]`:** emite `NACK:<token>:<id>[:modelo]:<razon>` (4-5 segmentos,
  7.5) con razones cerradas. El formato enriquecido
  (`NACK:...:<msg_id>:<run_id>`, 7 segmentos) SOLO viaja al wire cuando se pasa
  `--for-run-id`: `msg_id` y `run_id` van juntos, y el parser distingue el
  enriquecido (6 campos tras `NACK:`) del genérico. El audit guarda la razón.
- **`cross resume --to ses_X --task-id TX [--from] [--text]`:** implementa el
  RESUME de 12.10 (§6.1c). Envía `prompt_async` a la misma sesión con
  instrucción de continuación; NO crea `msg_id` nuevo, NO toca el outbox, NO
  incrementa `attempt` (§12.1).
- **`cross restart-task --msg-id X [--to] [--text]`:** implementa el RETRY de
  12.10 con el MISMO `msg_id` (idempotente): attempt+1 persistido en el outbox,
  estado de vuelta a `EN_VUELO`. Errores: `OUTBOX_MSG_NOT_FOUND` /
  `MAX_RETRIES_EXCEEDED` (máx `max_retries` de `cross.config.json`).
- **`cross nudge --to ses_X --task "..." [--token]`:** prompt firme que ignora
  `Continue`/orientaciones previas (antídoto al descarrilamiento por
  auto-continuación, 6.1c).
- **`cross escalate --msg-id X --to ses_Y --reason "..." [--run-id] [--apply]`:**
  anexa la línea `URGENTE` canónica a `escalated.md` (12.6). Sin `--apply` NO
  notifica (dry-run); con `--apply` envía wake-on-write al destino.
- **`cross dlq --msg-id X [--to] [--retries] [--flag F] [--summary]`:**
  anexa la línea DLQ a `dlq-mensajes.md` (12.7) con flags cerrados
  `HUMAN_REVIEW|NACK_ORIGINATED|QUARANTINE|PROVIDER_DOWN` y marca el outbox
  `ESTADO=DLQ`.
- **`cross quarantine --msg-id X --reason "..." [--check-log] [--minutes N]`:**
  DLQ con `flag=HUMAN_REVIEW` + outbox `ESTADO=QUARANTINE`. Con `--check-log`
  diagnostica por `opencode.log` (ver `diagnose`) y anexa `log=<clasificación>`
  al resumen del DLQ.
- **`cross diagnose --msg X [--outbox-file] [--minutes N]`:** clasifica el
  destino del msg leyendo `opencode.log` (config `log_path`) en la ventana de N
  minutos (10 por defecto), filtrando por el `dest` del outbox. Clasificaciones:
  `PROVIDER_DOWN` (`[504]`/`[524]`/`stream error 504|524`/`connect timeout`/
  `ENOTFOUND`/`Rate limit exceeded`), `AGENT_SLEEPING` (`exiting loop`),
  `CONFIG_ERROR` (otro `stream error`), `NO_ERROR`, `NO_DATA`. La ventana y el
  timestamp se comparan en UTC (la `Z` del log es obligatoria).

Reglas de escritura: todos estos subcomandos son **append-only** sobre sus
archivos (audit, escalated, DLQ, outbox); no reescriben líneas previas.

## Apéndice A: Mejoras futuras

> **Consenso (Rondas de mejora 2026-08-10):** se documentan como futuro; NO
> prometer funcionalidad que el servidor no soporta aún.
>
> **Backlog priorizado v1.7 (consenso asesores 2026-08-11):**
> | Prioridad | Riesgo | Propuesta | Nota |
> |---|---|---|---|
> | ALTA | BAJO | **SQLite (`cross.db`)** | Resuelve la race condition de `Add-Content` (CROSS_WINDOWS.md #6). Nota revisión externa: es mejora arquitectónica, no reparación urgente (la regla de escritor único ya elimina T10 del protocolo). Decidir por crecimiento real. |
> | ALTA | BAJO | **`session.status`/idle/error** | Ya existe `GET /session/:id`; usarla como señal primaria de presencia y conservar la heurística de crecimiento como fallback (revisión externa). |
> | MEDIA | MEDIO-ALTO | **SSE / long-polling** | Solo si el backend lo soporta; si no, NO implementar. Probar experimentalmente antes: `GET /event`, crear actividad, observar `session.status`/`message.updated`/`session.idle`/`session.error` (revisión externa). |
> | BAJA | BAJO | **SDK `@opencode-ai/sdk`** | Mejora DX; `curl`+ASCII actual funciona. Verificar semántica antes. |
> | BAJA/MEDIA | ALTO | **`session.abort`** | Solo opt-in / soft-abort primero. Abortar a ciegas puede dejar estados inconsistentes. |

- **Long-polling / SSE:** si la API de OpenCode Desktop llega a soportarlos,
  sustituir el polling activo (sección 6) por estos mecanismos para reducir
  carga y latencia. Fuera de alcance en v1.1 (requiere soporte de backend).
- **Operaciones en lote (batch):** enviar/leer varias sesiones en una llamada.
- **Heartbeat centralizado:** revisitar `heartbeat.json` solo si `GET /session/:id`
  no cubre presencia, con un mecanismo de escritura con bloqueo.
- **Wrapper con modo `--aviso-atasco` (propuesto por model-d, v1.3):** que
  `send_message.ps1` cuente los reintentos fallidos y, tras 3 fallos, envíe
  automáticamente `ESTANCADO-Rx:<ID>:<MODELO>` a la sesión del líder y aborte,
  en lugar de dejar al agente intentando comandos a ciegas (ver 11.6).
- **Elección de líder / eliminar SPOF (recomendado por revisión externa,
  2026-08-11):** mecanismo para que otra sesión asuma la coordinación si el
  líder no escanea el outbox (12.10) o no responde, p. ej. detección de
  outbox con `EN_VUELO` vencido y ausencia de gestión reciente del líder.
  Aceptado como trade-off en v1.6 (12.13).
