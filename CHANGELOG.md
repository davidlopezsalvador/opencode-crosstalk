# CHANGELOG — CROSS_TALK (historial del protocolo)

Registro de versiones, descubrimientos y pitfalls del protocolo Cross-Talk.
Las **reglas vigentes** están en `CROSS_TALK.md`; este archivo es solo historia.
Dividido de `CROSS_TALK.md` el 2026-08-11 (revisión externa: el documento
mezclaba especificación vigente con changelog y con pitfalls de PowerShell).

---

## Versiones

### Revision del sistema - fix F4-F7 (2026-08-13)

Tolerancia a formatos históricos en delivery_log y outbox (hallazgos menores de
la revisión con los 4 asesores). Ver `whiteboard/38_sintesis_revision_sistema.md`:

- **F4/F6 (metrics, delivery_log):** `Get-CrossMetrics` (cross-diagnostic.psm1)
  clasificaba por el flag `ack` de cada línea; las líneas históricas
  `CONFIRMADO` con `ack=false`/`attempt=0` (formato experimental de tests
  viejos, dest=ses_X) caían a OTHER y distorsionaban las tasas. Fix: clasificar
  por `state` (todo `CONFIRMADO` cuenta como ACK, incluye fire-and-forget y el
  formato experimental) y acceso tolerante a propiedades opcionales
  (`nack`/`reason_code`/`err`/`ack_latency_ms`/`attempt`/`session_growing`/
  `cmd` vía `PSObject.Properties`, necesario bajo strict mode). Las líneas
  no-JSON se ignoran sin romper metrics. Verificado en vivo: total=91, ACK=20
  (antes 2 caían a OTHER), OTHER=2 (solo líneas con state vacío).
- **F7 (validate, outbox):** las entradas históricas T9 y TESTD
  (2026-08-11) vivían en la sección "## Activo (formato v1.6)" con formato
  anterior (`lease=...@UTC+3min EXPIRADO|sucesor=...`), y `cross validate`
  fallaba (code 2, "PROCESADO sin CONFIRMADO en outbox" para TESTD) además del
  warning "lease sin deadline UTC". Fix: movidas a la sección "## Historico
  (formato anterior a v1.6; no parsear como v1.6)". `cross validate` pasa
  limpio (0 errores, 0 warnings).
- **F5 (audit, sin código):** verificado que el audit sí registró los ACK/ENV
  de las fases 4-5; el gap de fechas del volcado era histórico. No requiere
  acción.
- Tests: nuevo T-metrics (19 aserciones: reclasificación por estado, NACK por
  reason_code, EXPIRADO→TIMEOUT, EN_VUELO→NO_ACK, líneas rotas ignoradas,
  filtros by-agent/since/until, dest vacío→'(sin dest)', since/until inválido→
  USAGE_ERROR [cubre D1], LOG_NOT_FOUND); T-validate +2 aserciones (sección
  F7: históricos con formato mixto fuera de Activo no generan errores ni
  warnings); T-cli +5 aserciones (wiring CLI de metrics con --log-path,
  USAGE_ERROR code 64, LOG_NOT_FOUND).
- **BUG E2 (métricas, delivery_log):** `Write-CrossDeliveryLog`
  (cross-delivery.psm1) accedía a `$Result.attempt`/`ack_latency_ms`/etc.
  directamente; si el hashtable `Result` no traía todas las claves (Result
  parcial), bajo `Set-StrictMode 2.0` lanzaba PropertyNotFoundException y
  rompía send a mitad del log. Fix: helper `Get-ResultVal` que tolera
  hashtables y PSCustomObject (mismo patrón F4/F6). Cubierto por T-delivery.
- Tests: T-delivery +8 (Write-CrossDeliveryLog: formato JSONL, audit,
  Result parcial); T-transport +7 (Get-CrossPortFromLog con fixture de dir
  de logs, Get-CrossPortByScan encuentra puerto sano); T-poll +10 (tabla
  Get-PollDiagnostic en ramas directas: EXPIRADO/TRANSFERIDO→TERMINAL,
  AckDetected/NackDetected, LeaseVencido, UNKNOWN, PROVIDER_DOWN,
  CRECE_SIN_ACK, QUIETA_SIN_ACK); T-validate +4 (outbox malformada→warn,
  estado no v1.6.1 en Activo→warn). `Get-PollDiagnostic` ahora es función
  exportada del módulo cross-diagnostic.
- Regresión: **28 suites / 520 aserciones / 0 fallos** (1 fallo transitorio
  de scan TCP por estado del server real; aislado 19/0). Práctica CROSS cerrada.

### Revision del sistema - fix F1/F2 (2026-08-13)

Revisión de campo con 4 asesores (model-a, model-d, model-f, model-b) en la práctica
end-to-end (ver `whiteboard/38_sintesis_revision_sistema.md`). Se corrigieron
los 2 hallazgos accionables:

- **F1 (diagnose):** la matriz de clasificación de `Get-CrossDiagnose`
  (cross-action.psm1) clasificaba `message="stream error"` sin código 5xx
  (p. ej. `AI_APICallError: Upstream request failed: Endpoint is unavailable`)
  como `CONFIG_ERROR` → riesgo de QUARANTINE/DLQ falso para agentes con
  errores transitorios de proveedor. Fix: nueva matriz con 2 ramas:
  `CONFIG_ERROR` (solo auth/modelo: `model not found`, `invalid model`,
  `unauthori[sz]ed`, `invalid api key`, `authentication failed`, `401`/`403`)
  antes de `PROVIDER_DOWN` (ampliado a `AI_APICallError`, `Upstream request
  failed`, `Endpoint is unavailable`, `stream error`, `[5xx]`, timeouts,
  `ENOTFOUND`, `ECONNREFUSED`, `ETIMEDOUT`, `Rate limit exceeded`).
  Validado contra el log real del evento de model-d (12:20Z): ahora
  `PROVIDER_DOWN / renovar lease y esperar (12.10)`.
- **F2 (auto-sweep de vencidos):** los EN_VUELO con lease vencida se quedaban
  colgados hasta un `scan` manual. Fix: `Invoke-CrossAutoSweep`
  (cross-state.psm1) marcado EXPIRADO + audit (`Tipo=SCAN`) y disparado al
  inicio de `cross send` (excluyendo el msg en curso vía `-ExcludeMsgId`).
  El campo `swept_expired`/`swept_count` se expone en el resultado de send.
- Tests: T-diagnose 28 aserciones (casos provider sin 5xx, auth/modelo→
  CONFIG_ERROR) y nuevo T-sweep (9 aserciones: solo vencidos, exclusión del
  msg en vuelo, sin mutación si no hay vencidos).
- Regresión: 24 suites / 408 aserciones / 0 fallos.

### Revision del sistema - fix E1 (2026-08-13)

Test E2E con respuestas reales de los 4 asesores (tarea 39_tarea_e2e.md):
model-d confirmó con el envelope canónico (`ack_latency_ms=65733`) pero
model-a, model-f y model-b respondieron al líder en formatos alternativos
(`Firma: TOKEN:MSG-...`, `token MSG-...` en medio del texto, `TAREA-E2E:ACK:...`)
y el motor los marcó NACK_TIMEOUT aunque la respuesta llegó.

- **E1 (ACK estricto):** `Parse-CrossAckText` (cross-delivery.psm1) ahora
  reconoce variantes reales de ACK sin romper el canónico: el MSG-token
  declarado como `TOKEN:MSG-...`, `token MSG-...` o desnudo prevalece y extrae
  emisor/modelo del sufijo `:emisor:modelo`; `:ACK:...` precedido de dos
  puntos cuenta como ACK; y una declaración `TOKEN:MSG-...` sin prefijo ACK
  ya es ACK. Validado con los 3 casos reales del E2E.
- Tests: T-delivery +5 aserciones (sección E1).
- Regresión: 24 suites / 413 aserciones / 0 fallos.
- F2 validado en vivo: el send de model-d barrió los 3 EN_VUELO vencidos
  históricos (D89796, F88299, BF5936) → EXPIRADO (`swept_count=3`).

### Revision del sistema - fix F3 (2026-08-13)

- **F3 (whoami por config):** `cross whoami` reportaba siempre la identidad
  del líder porque la config es compartida. Fix: overrides explícitos
  `--session-id` / `--model` / `--role` (`identity_source=override`), detección
  de `shared_config` (my_session_id == lider_session_id), y la auto-detección
  de identidades reales vía `cross sessions` (GET /session con title/model/id).
- Tests: nuevo T-whoami (17 aserciones).
- Regresión: 25 suites / 430 aserciones / 0 fallos.

### cross.ps1 Fase 5 - wrapper + scan retry-auto + metrics + race test (2026-08-13)

Implementados los 4 puntos del plan Fase 5 (recomendación external-reviewer en 33_sintesis):
wrapper legacy `send_message.ps1`, `cross scan --retry-auto`, `cross metrics` y
el test de race multi-emisor sobre outbox.md. Ver `whiteboard/34_sintesis_fase5.md`.

- **Wrapper `send_message.ps1` (firma legacy):** `-Destino -Texto [-NoReply]
  [-Puerto] [-Password] [-LegacyMode]`. Modo normal: autogenera
  `msg_<emisor>_<yyyyMMdd-HHmmss>-<rand6>`, inserta la línea OUTBOX tras
  `## Activo` (formato v1.6.1) y delega en `cross send --msg ... --dest ...
  --text ... [--no-wait]`. `-LegacyMode` = HTTP directo (comportamiento v1.6.1).
  La NOTA para el agente sale por **stderr** (el JSON de stdout no se corrompe);
  `exit $LASTEXITCODE`. `whiteboard/send_message.ps1` quedó como shim delegante.
- **`cross scan --retry-auto [--apply] [--max-attempts N]`:** diagnóstico por
  defecto (dry-run); `--apply` ejecuta. Clasifica cada EN_VUELO vencido con
  `Get-CrossDiagnose`: PROVIDER_DOWN→RENEW_LEASE, AGENT_SLEEPING/NO_DATA→
  RESTART_TASK, CONFIG_ERROR→QUARANTINE (--check-log), NO_ERROR→NOTIFY_LEADER.
  `Restart-CrossTask` valida `MAX_RETRIES_EXCEEDED` (reporta en `err` del plan,
  sin bucle ciego). Con `PortArg=0` actualiza estado/attempt pero no envía.
- **`cross metrics [--since|--until] [--by-agent]`:** métricas de entrega desde
  `delivery_log.jsonl` (total, por agente y por outcome, rates ack/nack/error/
  timeout, p50/p95 de ack_latency_ms, top razones NACK, intentos).
- **BUG DD (crítico, concurrency):** la inserción de la línea OUTBOX del wrapper
  era read-modify-write NO atómica. Con 2+ procesos concurrentes, el último
  write ganaba → se perdían líneas → `OUTBOX_MSG_NOT_FOUND` en `cross send`.
  Fix: **mutex nombrado por hash de la ruta del outbox** (`Get-OutboxMutex`)
  que serializa la inserción (`Add-OutboxEntry`, exportada, con backoff
  100..1200 ms y verificación post-write) y los updates in-place
  (`Update-OutboxLine`); además `Get-OutboxEntry` (lectura consistente bajo el
  mutex) usada por `Set-OutboxEstado`/`Renew-CrossLease`/`Set-OutboxAttempt` y
  por `cross send` (antes leía sin lock y podía ver el archivo truncado a mitad
  de un write concurrente). Resultado: **80/80 msg_id únicos** en el race test.
- **T-race.ps1:** 4 jobs × 20 llamadas al wrapper = 80 envíos concurrentes,
  aislados vía `$env:CROSS_WHITEBOARD_DIR` (Import-CrossConfig lo respeta).
  Verifica 0 OUTBOX_LOCKED, 80 líneas OUTBOX únicas, sin corruptas, con ESTADO,
  80 JSON válidos y msg_id únicos en delivery_log, audit ≥80. **9/9 PASS.**
- **Verificado:** suite completa **23 suites, 386 aserciones, 0 fallos**
  (nuevos: T-race 9; T-cli sin cambios 36; regresión total de los 22 previos
  incluido E2E real 8/8). `cross metrics` validado por CLI sobre el
  delivery_log real (total=51, rates y latencias coherentes; filtros --by-agent/
  --since/--until OK).
- **Revisión external-reviewer del ZIP Fase 5 (2026-08-13) — veredicto:** "Fase 5 entregada y
  validada". BUG DD confirmado (raíz + fix correctos). 3 observaciones de
  calidad (O1/O2 no urgentes, documentadas) y 2 detalles menores + 1
  observación, cerrados en v2:
  - **D1 (menor, metrics):** `--since`/`--until` con formato inválido se
    ignoraban en silencio (`Parse` en try/catch vacío → filtro no aplicado).
    Ahora devuelve `USAGE_ERROR` code 64 con detalle (usar ISO8601).
  - **D2 (menor, metrics):** `top_nack` devolvía TODAS las razones ordenadas;
    ahora limita a las top 10.
  - **O3 (observación, metrics):** añadido `source: 'delivery_log.jsonl'` al
    output para dejar explícito que las métricas miden envíos vía `cross send`
    (no actividad de receptor/reactivaciones, que solo van a audit_log).
  - **O1/O2 (deferidos a backlog):** `Add-CrossLogLine` (audit) y
    `Add-IdempotenciaLine` (idempotencia) no usan mutex (append-atómico +
    retry cubren el volumen actual; aplicar mutex si aparecen pérdidas). La
    contención del mutex por ruta es aceptable para 3-5 agentes.
- **Verificado (revisión external-reviewer):** 23 suites, **386 aserciones, 0 fallos**
  (T-cli 36 sin regresión tras D1/D2/O3); `cross metrics` revalidado por CLI
  (`source=delivery_log.jsonl`, `--since "ayer"` → USAGE_ERROR 64).



Implementados los 9 subcomandos de acción en `cross/modules/cross-action.psm1`,
integrados en el CLI (`cross.ps1`, `ack`/`nack`/`resume`/`restart-task`/`nudge`/
`escalate`/`dlq`/`quarantine`/`diagnose`). Complementan la capa de LECTURA de la
Fase 4a (poll/status/reconcile/aviso-spof) con operaciones que sí mutan outbox,
escalated, DLQ y audit. Ver CROSS_TALK.md §7.5 y §12.6/12.7/12.10.

- **`cross ack --token T --for-msg-id X [--to] [--model]`:** emite
  `ACK:<token>:<id>[:modelo]` (3-4 segmentos, 7.1) al destino y lo registra en
  audit como `ACK|ENVIADO`.
- **`cross nack --token T --for-msg-id X --reason R [--note] [--for-run-id]`**:
  emite `NACK:<token>:<id>[:modelo]:<razon>` (4-5 segmentos) con razones cerradas
  (7.5); el formato enriquecido v1.7 (`NACK:...:msg_id:run_id`, 7 segmentos) solo
  viaja al wire cuando se pasa `--for-run-id` (msg_id+run_id juntos), para que el
  parser distinga el enriquecido del genérico.
- **`cross resume --to ses_X --task-id TX [--from] [--text]`:** instrucción de
  continuación ejecutable (§12.10). NO crea msg_id nuevo, NO toca el outbox y NO
  incrementa attempt (§12.1).
- **`cross restart-task --msg-id X [--to] [--text]`:** RETRY con el MISMO msg_id,
  attempt+1 persistido en el outbox; `OUTBOX_MSG_NOT_FOUND` /
  `MAX_RETRIES_EXCEEDED` (máx `max_retries` de config).
- **`cross nudge --to ses_X --task "..." [--token]`:** prompt firme que ignora
  `Continue`/orientaciones previas (antídoto §11 pitfall auto-continuación).
- **`cross escalate --msg-id X --to ses_Y --reason "..." [--run-id] [--apply]`:**
  línea `URGENTE` canónica en `escalated.md` (§12.6); sin `--apply` NO notifica
  (dry-run); con `--apply` envía wake-on-write al destino.
- **`cross dlq --msg-id X [--flag F] [--summary]`:** línea DLQ en
  `dlq-mensajes.md` con flags cerrados `HUMAN_REVIEW|NACK_ORIGINATED|QUARANTINE|
  PROVIDER_DOWN` (§12.7) y marca el outbox `ESTADO=DLQ`.
- **`cross quarantine --msg-id X --reason "..." [--check-log]`:** DLQ con
  `flag=HUMAN_REVIEW` + outbox `QUARANTINE`; `--check-log` diagnostica por
  `opencode.log` y anexa `log=<clasificacion>` al resumen.
- **`cross diagnose --msg X [--minutes N]`:** clasifica el destino del msg por
  `opencode.log` en la ventana de N minutos: `PROVIDER_DOWN` (504/524/connect
  timeout/ENOTFOUND/Rate limit) / `AGENT_SLEEPING` (exiting loop) /
  `CONFIG_ERROR` (stream error distinto) / `NO_DATA`.
- **BUGs cerrados durante desarrollo:**
  - **BUG S (crítico, audit):** `Write-AuditEntry` colisionaba el parámetro
    `$Nota` con la variable local `$nota` (PowerShell case-insensitive): la nota
    salía duplicada (`msg=x; msg=x`) y el texto propio se perdía. Renombrada la
    local a `$notaLine`.
  - **BUG T (crítico, tests):** los scriptblocks `-SendFn { param($d,$t)
    Fake-Send }` recibían los argumentos pero NO los reenviaban a `Fake-Send`
    (dest/text vacíos). Ahora `Fake-Send $d $t`.
  - **BUG U (medio, binding):** `[Parameter(Mandatory=$true)][string]` rechaza
    `''` en binding (`ParameterArgumentValidationErrorEmptyStringNotAllowed`)
    antes de la validación manual que devuelve `USAGE_ERROR`. Los `[string]`
    validados manualmente pasan a `[AllowEmptyString()]` (el CLI ya los castea a
    `[string]`, vacío incluido).
  - **BUG V (medio, diagnose):** el regex de timestamp descartaba la `Z`
    (`timestamp=(\d{4}-...:\d{2}:\d{2})`); `[datetime]::Parse(...).ToUniversalTime()`
    trataba el valor como local y en máquinas UTC+2 desplazaba -2h → líneas
    fuera de la ventana → `NO_DATA` falso. El regex captura `(?:\.\d+)?Z` y el
    parse usa `RoundtripKind`.
  - **BUG W (medio, clasificación):** la regex de `PROVIDER_DOWN` era
    `\[504\]|\[524\]` y no casaba `stream error 524` (sin corchetes) →
    `CONFIG_ERROR` falso. Añadido `stream error (504|524)`.
  - **BUG X (menor, segments):** `segments` reportaba `$segs.Count` (4) pero los
    tests contaban los segmentos del texto wire (`ACK:T1:sub:ses:model-b` = 5).
    Ahora `@($text -split ':').Count`.
  - **Fix tests:** T-nack alineado a la spec v1.7 (msg_id sin run_id NO
    enriquece la trama; enriquecido = 7 segmentos); T-quarantine `--check-log`
    usa timestamps relativos a `$now` (los fijos de 2026-08-12 quedaban fuera de
    la ventana → NO_DATA).
- **Verificado:** 22 suites, **354 aserciones, 0 fallos** (nuevos: ack 14, nack
  21, resume 13, restart-task 14, nudge 10, escalate 15, dlq 15, quarantine 13,
  diagnose 15; T-cli 36; E2E real 8/8 contra el servidor OpenCode Desktop).
- **Revisión external-reviewer del ZIP 4b (2026-08-13) — veredicto:** "Fase 4b funcionalmente
  completa; 1 bug crítico (BUG Y) debe cerrarse antes de Fase 5". Cerró 5 bugs:
  - **BUG Y (crítico, wire NACK):** `Send-CrossNack` con `--for-run-id` pero SIN
    `--model` emitía 6 segmentos (`NACK:token:id:razon:msg_id:run_id`), que el
    parser leía por la rama genérica `-ge 4` y mezclaba razon/modelo/emisor
    (misparse total). Fix (Opción B recomendada por external-reviewer): `Get-CrossMyModel`
    autoderiva el modelo desde `config.my_model` cuando no se pasa `--model`,
    tanto en `Send-CrossNack` como en `Send-CrossAck`; si aun así el enriquecido
    no tiene modelo → `USAGE_ERROR`. Ahora ACK/NACK básicos llevan SIEMPRE modelo
    (4/5 segmentos, §7.1/7.5 canónico) y el enriquecido nunca emite 6 segmentos.
    Test nuevo en T-nack: enriquecido sin `--model` → 7 segmentos parseables.
  - **BUG Z (medio, DLQ):** `Write-CrossDlq` usaba `entry.attempt` como
    `reintentos`; attempt cuenta entregas (attempt=1 → 0 reintentos). Ahora
    `reintentos = max(0, attempt - 1)` (también en el call de `quarantine`).
  - **BUG AA (medio, audit):** `Write-CrossDeliveryLog` escribía el audit con
    `AppendAllText` directo, saltándose el retry de `Write-AuditEntry` (el audit
    es multi-writer). Refactorizado a `Write-AuditEntry` (nota construida por
    partes, sin `msg=` duplicado).
  - **BUG BB (menor, escalated):** `Write-CrossEscalated` emitía el `msg_id`
    desnudo (`| msg_x |`); `Read-EscalatedLog` solo lo reconocía si empezaba por
    `msg_`. Ahora emite `msg_id=$MsgId` explícito → cualquier formato de msg_id
    parsea. Test nuevo en T-escalate.
  - **BUG CC (menor, restart-task):** spec v0.2 §7.10 pide
    `cross restart-task --max-attempts N`; el dispatch del CLI no lo pasaba.
    Añadido `[int]$MaxAttempts` a `Restart-CrossTask` (default config.max_retries)
    y el flag en `cross.ps1`. Test nuevo en T-restart-task.
- **Verificado (revisión external-reviewer):** 22 suites, **377 aserciones, 0 fallos** (nuevos:
  ack 14, nack 25 [BUG Y], resume 13, restart-task 17 [BUG CC], nudge 10,
  escalate 18 [BUG BB], dlq 17 [BUG Z], quarantine 13, diagnose 15; T-cli 36;
  T-delivery 53 [BUG AA]; E2E real 8/8 con wire que confirma el modelo:
  `ACK:...:leader-model` / `NACK:...:leader-model:CAPACITY`).

### cross.ps1 Fase 4a - revision external-reviewer v2 (2026-08-12)

Revisión externa del ZIP Fase 4a por external-reviewer: veredicto "Fase 4a validada",
luz verde condicionada. Cerró 1 bug crítico + 2 medios + 2 menores y 2
observaciones de diseño:

- **BUG M (crítico):** regex `msg=$MsgId` sin delimitadores en
  `Find-AuditOutcome` (`cross poll`) y en el lifecycle de `Get-CrossStatus`.
  Mismo patrón que BUG B (Fase 3): `msg_123` matcheaba la línea de `msg_1234`.
  Ahora `msg=<id>` requiere `(\s|;|\||$)` después (más `[regex]::Escape`).
- **BUG P (medio):** `Get-SessionState` solo hace growth-check si
  `status='busy'` o no hay status (antes siempre, 15 s por defecto). `cross
  status` con 5 agentes pasa de ~75 s a ~25 s.
- **BUG Q (medio):** `aviso-spof` notificaba a `$MySessionId` (mi propia
  sesión). Añadido `lider_session_id` a `cross.config.json`; la notificación
  va a la sesión del líder (fallback a `$MySessionId` si no está definido).
- **BUG O (menor):** el inter-iteration sleep de `poll` respeta `$SleepFn`
  (antes `Start-Sleep` hardcoded, intestable con IntervalMs reales).
- **BUG R (menor):** `dlq_by_flag` agrupa flags no cerrados (§12.7) bajo
  `UNKNOWN` (antes contaba cualquier string).
- **O2 (observación):** `claimed_orphaned` añade `claimer_status` (status de
  la sesión o `unreachable`), distinguiendo "claimer quieto (problema real)"
  de "no pude verificar (red)".
- **Mejora reconcile:** check-file existente pero vacío → `AMBIGUOUS` con
  recomendación `retry` (antes `investigate`, indistinguible de "hay contenido
  sin token").
- **Mensaje ACKED_QUIETA:** clarificado a "agente en busy sin crecimiento,
  posible atasco".
- **Verificado:** 13 suites, **235 aserciones, 0 fallos** (poll 19, status 21,
  reconcile 14, aviso-spof 18; T-cli 36).

### cross.ps1 Fase 4a - diagnosticos unificados (2026-08-12)

Implementados `poll`, `status`, `reconcile` y `aviso-spof` en el nuevo módulo
`cross/modules/cross-diagnostic.psm1`, integrado en el CLI (`cross.ps1`).
Todos son de LECTURA (no mutan outbox salvo `poll` marcando NACKED detectado en
audit, y `aviso-spof --apply` anexando AVISO-SPOF). Ver CROSS_TALK.md §12.14.

- **`cross poll --msg X [--timeout S] [--interval MS]`:** diagnóstico por
  mensaje con la señal primaria `session.status` + crecimiento (12.4/12.9):
  ACKED/NACKED/WORKING/ACKED_QUIETA/QUIETA_SIN_ACK/PROVIDER_DOWN/EXPIRED/
  TERMINAL/UNKNOWN, según la tabla de decisión. Bucle hasta deadline.
- **`cross status [--msg|--run-id|--agent]`:** resumen de outbox (por estado y
  por agente con estado de sesión), `expired_unmanaged`, idempotencia por
  estado, `claimed_orphaned`, `escalated_pending`, `aviso_spof`, `dlq_unread`/
  `by_flag` y `lifecycle` (con `--msg`).
- **`cross reconcile --msg X --check-file PATH [--expected-token T]`:**
  RECONCILE automático de 12.10: `CONFIRMED` (token en el check-file) /
  `AMBIGUOUS` / `NOT_FOUND`, con la línea donde aparece el token.
- **`cross aviso-spof [--apply] [--for ses_X]`:** detección pasiva de SPOF
  (12.13): EN_VUELO vencido propio + sesión quieta → `AVISO-SPOF` en escalated
  (solo con `--apply`); ajeno → aviso al líder. Dry-run por defecto.
- **Fix durante desarrollo:** `Get-CrossStatus` filtraba idempotencia por
  `run_id`, propiedad inexistente en `idempotencia-procesados.md` → eliminado
  el filtro (el log no lleva run_id; el outbox sí).
- **Verificado:** 13 suites, **223 aserciones, 0 fallos** (nuevos: poll 16,
  status 17, reconcile 12, aviso-spof 15; T-cli sube a 36 con wiring 4a).

### cross.ps1 Fase 3 - revision external-reviewer v2 (2026-08-12)

Revisión externa de `CROSS_cross_fase3_20260812.zip` por external-reviewer (8 puntos de
validación): veredicto "motor funcionalmente completo y validado", 7 bugs.
Cerrados todos + 2 observaciones de diseño:

- **BUG A (crítico, parser):** `Parse-CrossAckText` ahora reconoce el NACK
  enriquecido de 6 segmentos (v0.2 §3.4 Hallazgo #4 model-d)
  `NACK:<token>:<id>:<modelo>:<razon>:<msg_id>:<run_id>` y propaga
  `nack_msg_id`/`nack_run_id` en el resultado del motor. 4-5 segmentos siguen
  válidos (superset). Especificado en CROSS_TALK.md §7.5.
- **BUG B (crítico, outbox):** búsqueda de msg_id en `Update-OutboxLine` con
  delimitadores `OUTBOX | <msg_id> |` (antes substring: `msg_123` tocaba la
  línea de `msg_1234`). Aplica a Set-OutboxEstado/Renew-CrossLease (delegan).
- **BUG C (medio):** chequeo de "destino crece" con `WaitMs=15000` por defecto
  (antes 2000, falsos negativos), configurable vía `session_growing_check_ms`.
- **BUG D (medio):** `$renewed` se resetea entre intentos (cada intento puede
  renovar el lease 1× si el destino sigue creciendo).
- **BUG L (medio):** `attempt` persistido en la línea del outbox
  (`Set-OutboxAttempt`, `attempt=N`) antes de cada envío; `cross send` retoma
  tras un crash desde el intento real. `Set-OutboxAttempt` exportado.
- **BUG F (menor):** `Write-CrossDeliveryLog` crea `audit_log.md` (y su dir)
  si no existe, igual que `delivery_log.jsonl`.
- **BUG K (menor):** `cross scan --apply/--quarantine` reporta fallos de
  escritura (OUTBOX_LOCKED) en el campo `failed` (antes se caían al suelo).
- **Mejora external-reviewer (reason_codes):** añadidos `NACK_SERVER_ERROR` (5xx agotado),
  `NACK_HTTP_4XX`, `NACK_NETWORK` a la clasificación `Reason-Code`.
- **Limpieza:** eliminado `Set-OutboxEstado EN_VUELO` redundante en el path
  `--no-wait`; documentado `--ack-timeout 0` (sin ACK → CONFIRMADO) en el help.
- **Verificado:** 9 suites, **156 aserciones, 0 fallos** (delivery subió de 43
  a 53 con los tests de BUG A/B/L).

### cross.ps1 Fase 3 - motor de entrega + E2E real (2026-08-12)

Fase 3 implementada y validada de extremo a extremo (consenso en
whiteboard/29f_sintesis_delivery.md, decisiones D1-D4).

- **`cross send`:** entrega vía `POST /session/<dest>/prompt_async` con sobre
  12.1 (`Format-CrossEnvelope`) y espera ACK en la sesión del emisor
  (ventana `default_ack_timeout_s=120`, polling 3s). Opciones: `--no-wait`
  (fire-and-forget, outbox queda EN_VUELO), `--ack-timeout`, `--max-attempts`.
- **ACK/NACK:** `Parse-CrossAckText` valida `ACK:<token>:<id>:<modelo>` (7.1)
  y `NACK:<token>:<id>:<modelo>:<razon>` (7.5); también handshake
  `ACK-PROTOCOLO`/`NACK-PROTOCOLO`. NACK → outbox `NACKED` con razón.
- **Reintentos (tabla 12.9):** retry solo HTTP 0/408/429/5xx, máx 2 intentos,
  backoff 2s lineal. 404 → `DEST_NOT_FOUND` sin retry; 401/403 →
  `AUTH_FAILED` (config). Sin ACK tras max intentos → `EXPIRADO` con
  `ACK_TIMEOUT` y `reason_code` NACK_TIMEOUT.
- **Lease:** renovado 1× si el destino "crece" durante la espera (heuristico
  12.4a). `cross scan` lista EN_VUELO vencidos; `--apply` renueva lease,
  `--quarantine` marca QUARANTINE.
- **Trazabilidad:** `whiteboard/delivery_log.jsonl` (log estructurado por
  msg_id) + `audit_log.md` + `ack_latency_ms` como métrica básica.
- **E2E real (D4):** `tests/T-e2e.ps1` contra el servidor OpenCode Desktop
  (credenciales autodetectadas): happy ACK → CONFIRMADO, NACK → NACKED,
  404 → DEST_NOT_FOUND, y observabilidad. 8/8 PASS.
- **Verificado:** 9 suites, 146 aserciones, 0 fallos.
- **Pitfall corregido:** `"$var:`"` dentro de string double-quoted se parsea
  como referencia de unidad PowerShell → usar `${var}` (reincidente del BUG
  1/external-reviewer, ahora corregido también en tests).

### cross.ps1 Fase 1 - revision external-reviewer (2026-08-12)

Revisión del ZIP `CROSS_cross_fase1_20260812.zip` por external-reviewer: contrato de red
correcto en 7/7 puntos de validación. 9 bugs reportados; cerrados los 3
bloqueantes (BUG 1-3) antes de Fase 2 y los 6 restantes (BUG 4-9). Verificado:
45/45 tests (T-cli 29/29, T-transport 16/16).

- **BUG 1 (bloqueante):** eliminado el hardcode de puerto `13537` en
  `Get-CrossPortByScan`. El scan ahora verifica CADA candidato con
  `/global/health` (sin falsos positivos) y ya no depende del entorno de
  leader-model. Verificado: rango con el puerto real lo encuentra; rango vacío
  no devuelve nada.
- **BUG 2 (bloqueante):** `config --set` infiere tipo desde el valor existente
  (int/long → `[long]::TryParse`, bool → true/false/1/0/yes/no, array → error
  64). `port_cache_ttl_s=45` se guarda como número, no string.
- **BUG 3 (bloqueante):** `config --set` valida contra la spec v0.1 §4.1:
  `my_session_id` debe empezar por `ses_`; `default_ack_timeout_s` entero
  30-600; `default_lease_minutes` 1-30; `max_retries` 0-5; `max_saltos` 0-5;
  `protocol_version` debe ser `1.6.1` (warn, no bloquea). Violaciones → code 64.
- **BUG 4:** `duration_ms` ahora mide el comando real (Stopwatch en cada
  subcomando, `Out-Result -Watch`); eliminada la lógica de calcularlo desde `ts`.
- **BUG 5:** errores HTTP clasificados: 5xx → `HTTP_5XX`, 401 → `AUTH_FAILED`,
  404 → `NOT_FOUND`, resto → `HTTP_4XX`. `read` con sesión inexistente devuelve
  `NOT_FOUND` con code 64 (uso), no 3 (transporte).
- **BUG 6:** tests sin paths ni session_ids hardcode; leen `cross.config.json`
  y derivan la raíz CROSS (portables a otros entornos).
- **BUG 7:** flags desconocidos emiten WARN a stderr (`--jsno` ya no pasa
  silencioso).
- **BUG 8:** `--role` ahora es case-insensitive (`--role=USER` filtra igual).
- **BUG 9:** el módulo comprueba `curl.exe` en PATH (`Import-CrossConfig`
  lanza `CURL_NOT_FOUND` si no está).
- **Pitfall corregido:** `$key:` dentro de un string double-quoted se interpreta
  como referencia de drive (`$key: foo`); usar `${key}`.
- **Pitfall corregido:** `Split-Path -Parent` no resuelve `..` en tests; usar
  `[System.IO.Path]::GetFullPath`.

### cross.ps1 Fase 1 - transporte (2026-08-12)

Primera fase del CLI `cross.ps1` implementada (contrato spec external-reviewer v0.1, consenso
4/4 asesores en whiteboard/28f_sintesis_cli.md). Ubicación: `CROSS\cross\`
(FUERA del whiteboard, según consenso). Estructura modular: entry
(`cross.ps1`) + módulo de transporte (`modules/cross-transport.psm1`) + lib de
formato (`lib/cross-format.psm1`) + tests (`tests/`). Verificado: 39/39 tests.

- **Subcomandos utilidad:** `health`, `whoami`, `sessions [--directory]`,
  `read --session ... [--limit] [--since] [--role]`, `config [--get|--set]`,
  `--help`.
- **Autodetección D3:** orden env → .env → cache TTL 60s (hash de password)
  → regex en main.log → scan TCP → error. `--no-cache`, `--health-skip`,
  `--port`, `--password` como overrides.
- **Salida D5:** JSON por defecto (una línea), `--human` y `--quiet`
  alternativos. ASCII-safe en todas las salidas.
- **Códigos de retorno:** 0 ok, 3 fallo de transporte/API, 64 uso/config,
  70 error interno.
- **Pitfall corregido:** `switch -Regex` en PowerShell ejecuta TODAS las ramas
  que matchean; `break` por rama es obligatorio (el flag `--directory` se
  sobrescribía con `$true` por la rama genérica).
- **Pitfall corregido:** `-f` dentro de `[Console]::WriteLine("..." -f $a,...)`
  se descompone en modo argumento; envolver en paréntesis.
- **Pitfall corregido:** `Set-StrictMode 2.0` en módulos rompe `$obj.$key` si la
  clave no existe; usar `$obj.Contains($key)` + indexador.

### v1.1 (2026-08-10)

Consenso de 3 asesores (model-c, model-b, model-d) tras 3 rondas de mejora. Aportes
integrados: sección 7 (ACK), sección 8 (renumerada, coordinación), sección 9
(auditoría), sección 10 (monitoreo), sección 11 (problemas conocidos ampliado),
apéndice A (mejoras futuras) y wrapper opcional `send_message.ps1` (4e). Las
mejoras anteriores siguen vigentes; el cambio numérico es por inserción de
secciones nuevas.

### v1.2 (2026-08-10)

Cambios solicitados por el usuario humano tras la v1.1: (a) la firma de los
tokens incluye el **nombre del modelo** (`TOKEN:<ID_SESION>:<MODELO>`,
secciones 4d, 5, 7.1, 9.1) para que el usuario lea el modelo de un vistazo, y
(b) los agentes saben que el líder puede **revisar su sesión desde fuera** para
detectar atascos y, si no pueden completar la tarea, escriben un aviso en su
propio chat (sección 6.1e).

### v1.3 (2026-08-10)

Refinamientos menores acordados por los 3 asesores al validar la v1.2:
aclaración del ACK con el modelo del emisor al final (7.1), columna MODELO en
el log (9.1), ejemplo concreto de token firmado en 4d, error HTTP exacto en el
aviso de chat (6.1e) y `--aviso-atasco` del wrapper como mejora futura
(apéndice A). El parseo de tokens tolera 3 o 4 segmentos (`TOKEN:ID` o
`TOKEN:ID:MODELO`).

### v1.4 (2026-08-10)

Autodetección obligatoria de credenciales antes de CADA envío. Tras un
incidente real (model-b usó puerto y password viejos y su voto no llegó aunque el
script reportó éxito), se establece la regla de no hardcodear nunca
puerto/password (sección 1), el wrapper `send_message.ps1` autodetecta siempre
e ignora valores fijos (4e), y se documenta el caso en problemas conocidos
(11, punto 9).

### v1.5 (2026-08-10)

Lecciones de la tarea Bugs TXBridge + aportes de los 3 asesores. Pitfalls
documentados: BOM en JSON → HTTP 500 (sección 4, con preferencia ASCII — aporte
model-c), descarrilamiento por auto-continuación "Continue if you have next
steps..." (6.1c), identidad del emisor en el mensaje del líder (4d, 5, pitfall
model-d) y **canal principal = API** (responder solo en el chat es fallo de
entrega; 5, petición del usuario). `prompt_async` queda como método ESTÁNDAR
(4c, aporte model-d), responder con el mismo token recibido (5, aporte model-c)
y nueva sección 8.1 "Análisis de proyectos grandes" (aporte model-c). Nueva
sección 8.2 "Localización de herramientas" (pitfall python/Windows Store,
petición del usuario). Validado el flujo de 3 rondas
análisis→verificación→consenso (apartado 27). Cambios solo aditivos, sin
cambios de reglas.

#### Ampliación v1.5 (2026-08-11, competición de acertijos)

Pitfall probado empíricamente — `noReply: true` guarda el mensaje pero NO
despierta al agente destino (sección 5.1). Regla reforzada: responder SIEMPRE
con `prompt_async` sin `noReply`.

### v1.6 (2026-08-11)

Protocolo anti-sueño y garantía de wakeup. Consenso de 4 asesores (model-c,
model-d, model-b, model-a) tras 3 rondas de mejora. Nueva sección 12: sobre de
mensaje estándar con `msg_id`, outbox durable previo al envío, ACK en frontera
de turno, presencia pasiva (sin PING/PONG), lease con sucesor, canal de
escalada, DLQ, idempotencia, circuit breaker A/B/C y scan de recuperación
RETRY/RESUME/RECONCILE/QUARANTINE. Eje central (petición del usuario): que
NINGÚN mensaje quede dormido y todo agente se pueda despertar. Ajustes
integrados de model-d (timeout ACK 120s, sucesor por defecto = siguiente en
turnos, msg_id con prefijo de emisor, outbox actualizado solo por el emisor,
RECONCILE con verificación de archivo de salida) y de model-a (ACK con formato
completo 7.1, lease con sucesor explícito en el sobre). Las secciones 1-11 y el
apéndice A siguen vigentes; los cambios son aditivos.

#### Ajustes posteriores v1.6 (2026-08-11, campaña de tests)

- **§12.3 fijado en 120s SIN backoff** con decisión por dos señales (sesión
  crece → renovar lease; quieta → circuit breaker). El §7.3 (30s/backoff
  30/60/120) queda subordinado a §12.3 para mensajes con `requiere_ack=true`
  (precedencia documentada en 7.3).
- **§12.8 y §12.12:** terminología corregida de "exactly-once" a **at-least-once
  con deduplicación por `msg_id`** (efectively-once), tras revisión externa.
- **§12.13 (nuevo):** trade-offs aceptados — SPOF del líder documentado como
  limitación explícita (sin elección de líder en v1.6; mitigación por archivos
  legibles y supervisión humana). Elección de líder añadida a Apéndice A.

#### Reestructuración (2026-08-11, tras revisión externa external-reviewer + external-reviewer-2)

- **División del documento:** el historial de versiones y el "Resumen de lo
  descubierto" (32 hallazgos) se movieron de `CROSS_TALK.md` a este archivo
  (`CHANGELOG.md`). `CROSS_TALK.md` queda como documento SOLO de reglas
  vigentes (1180 → 1054 líneas).
- **Apéndice B (nuevo):** pitfalls de PowerShell 5.1/Windows consolidados
  (JSON/BOM, mojibake, rutas, `&&`, `${var}`, Add-Content concurrente,
  python/Windows Store), aislados de las reglas de protocolo. La sección 11
  conserva los ítems 1, 2, 7, 8 con delegación al Apéndice B (la numeración
  11.x no cambia para no romper referencias).
- **Deriva de formato corregida:** `whiteboard/outbox.md` reescrito con la
  gramática canónica v1.6 (las líneas antiguas de stress se movieron a la
  sección "Histórico"); la entrada T9 quedó como CONFIRMADO (estaba EN_VUELO
  con duplicado espurio con espacio inicial). `whiteboard/escalated.md` sin
  BOM. Normalizado CRLF → LF en los archivos operativos.
- **Diario fuera de whiteboard:** `whiteboard/15_charla_conciencia.md` (93 KB)
  movido a `diario/15_charla_conciencia.md`; referencias en CROSS_TALK.md
  (12.10), 16_diario_conversaciones.md y 26_informe_maestro.md actualizadas.

### v1.6.1 (2026-08-11)

Correcciones de semántica tras la revisión externa (external-reviewer + 4 asesores) sobre
la v1.6. NO son cambios de protocolo nuevos, sino aclaraciones y limpieza; la
v1.7 real llegará cuando se implemente y pruebe el backlog. Aplicado en
CROSS_TALK.md:

- **RESUME ≠ RETRY (corrección principal de la revisión externa):** `sigue` es
  RESUME (misma sesión + contexto + task_id implícito), NO retransmite el
  mensaje lógico y no lleva `msg_id`. RETRY es retransmisión del MISMO `msg_id`
  (idempotente). Corregido en §6.1c y §12.5(b), que mezclaban ambos.
- **Identidades formales (nuevo §12.1):** `task_id`, `run_id`, `msg_id`,
  `attempt`, `session_id` definidas como identidades independientes.
- **§12.3 terminología:** "ACK timeout" → "ACK decision window de 120s" (si la
  sesión crece se espera otra ventana; no es fallo a los 120s).
- **§6.1d simplificada:** regla de partición — mensajes con ACK → §12.3
  gobierna; mensajes sin ACK → §6.1d gobierna. Sin doble interpretación.
- **§12.6:** la afirmación de "innovación sin equivalente" se suaviza a "patrón
  de coordinación por estado compartido desarrollado para CROSS" (sin afirmar
  ausencia de equivalente en A2A/MCP).
- **§12.13 AVISO-SPOF:** detección pasiva por asesores al final del turno
  (escaneo ligero del outbox por `EN_VUELO` vencido para su ID → aviso en
  `escalated.md`), sin reelección de líder ni toma de tarea (consenso de los 4).
- **Limpieza documental:** Apéndice B (pitfalls PowerShell/Windows) movido a
  **`CROSS_WINDOWS.md`**; eliminadas las secciones "Historial de
  descubrimientos" y "Apéndice B" de CROSS_TALK.md (referencias de la sección
  11 actualizadas a `CROSS_WINDOWS.md`); CROSS_TALK.md queda SOLO con reglas
  vigentes (~1147 líneas).
- **Apéndice A:** backlog priorizado para la v1.7 real — SQLite (ALTA/bajo) y
  `session.status` (ALTA/bajo) primero; SSE condicional al backend (probar
  `GET /event` experimentalmente antes); SDK baja; `session.abort` opt-in/soft.
  Decisión pendiente: SQLite es mejora arquitectónica, no reparación urgente
  (la regla de escritor único ya elimina la concurrencia T10 del protocolo).

#### Ajuste final v1.6.1 (2026-08-11, segunda revisión external-reviewer)

- **Effectively-once acotado (§12.8 y §12.13):** la deduplicación por `msg_id`
  da effectively-once SOLO para operaciones idempotentes; para las no
  idempotentes se requiere RECONCILE o confirmación del efecto. Se elimina el
  exceso "effectively-once por construcción".
- **Semántica de `attempt` (§12.1):** RETRY → +1, TRANSFER → +1, RESUME →
  no incrementa (no es una entrega nueva).
- **RESUME ejecutable (§12.10):** se especifica cómo se hace: `prompt_async`
  sobre la misma `session_id` con instrucción de continuación basada en el
  checkpoint; sin reusar `msg_id`.
- **Limpieza documental completa:** eliminados los rastros de historial/
  apéndices de CROSS_TALK.md (solo reglas vigentes).

#### Correcciones de formato para el CLI (2026-08-11, aporte external-reviewer)

external-reviewer (tercera revisión externa) fijó los formatos EXACTOS que el futuro CLI
`cross.ps1` deberá parsear, eliminando variaciones toleradas:

- **CLAIMED (§12.8):** nuevo estado en la máquina de estados de idempotencia
  (`CLAIMED` → `PROCESADO`) que cubre la ventana 30-90 s del procesamiento LLM
  y evita la race de doble procesamiento. Formato EXACTO:
  `msg_id | timestamp_claim | modelo_claimer | CLAIMED_BY=ses_X` (sin espacios
  extra, sin variaciones). Retry solo si no hay línea o si el claimer está
  quieto (doble lectura 12.4). Aplicado a `CROSS_TALK.md` y
  `whiteboard/idempotencia-procesados.md`.
- **Handshake de protocolo (§4d):** el mensaje de la tarea lleva
  `PROTOCOLO: CROSS-TALK v1.6.1`; el asesor responde `ACK-PROTOCOLO:1.6.1`
  (tres segmentos EXACTOS, sin `v`, sin prefijo) en 30 s. Versión distinta →
  líder envía resumen de reglas críticas inline; agente sin protocolo →
  resumen + reintento; respuesta `NACK-PROTOCOLO:version_no_soportada:<versión>`
  → el líder decide continuar o excluir. Se repite al inicio de cada tarea.
- **NACK explícito (§7.5 nuevo):** el asesor que no puede procesar declara
  `NACK:<token>:<ID>:<MODELO>:<RAZON>` en vez de procesar a ciegas o callar.
  Razones cerradas: `CAPACITY | TOOL_MISSING | AMBIGUOUS_TASK |
  PROVIDER_DOWN | OTHER` (sin texto libre). Reasignar, abortar o escalar;
  no penalizar al emisor del NACK. (La antigua §7.5 "Relación" pasó a §7.6.)

#### Correcciones de formato external-reviewer F1-F4 + O1-O2 (2026-08-11)

Tras la verificación de external-reviewer del ZIP con las 3 correcciones, se cierran 4
fallos menores de formato y 2 observaciones de diseño antes de la campaña de
tests:

- **F1:** `outbox.md` declara el nuevo estado `NACKED` en la lista canónica
  (`EN_VUELO / CONFIRMADO / EXPIRADO / TRANSFERIDO / NACKED`).
- **F2:** `dlq-mensajes.md` y §12.7 añaden el campo `flag` al formato DLQ
  (`... | ESTADO=SIN RECOGER | flag=HUMAN_REVIEW | "resumen"`), con valores
  cerrados `HUMAN_REVIEW | NACK_ORIGINATED | QUARANTINE | PROVIDER_DOWN`.
  §7.5 ya no menciona "flag" como idea: queda especificado.
- **F3:** §7.5 añade la tabla de acción recomendada del líder por cada razón
  de NACK (`CAPACITY` reasignar sin +1 attempt; `TOOL_MISSING` proveer
  ruta/herramienta o reasignar; `AMBIGUOUS_TASK` reformular + nuevo msg_id;
  `PROVIDER_DOWN` esperar/excluir; `OTHER` DLQ con `flag=HUMAN_REVIEW`).
- **F4:** §9.1 amplía TIPO válidos del audit_log con `ACK-PROTOCOLO`, `NACK`,
  `NACK-PROTOCOLO`, `CLAIM`, `DONE`, `RELEASE`.
- **O1:** `idempotencia-procesados.md` pasa a **log append-only** (como el
  outbox): la transición `CLAIMED → PROCESADO` y el `release` se anexan como
  líneas NUEVAS (`PROCESADO` / `SUPERSEDED_BY=ses_Y`), nunca se reescriben.
  El parser del CLI lee la ÚLTIMA línea de cada `msg_id` como estado vigente.
  Elimina la race de la edición in-place en PowerShell (Get-Content →
  Set-Content no es atómico) sin SQLite.
- **O2:** nueva §4f "Reglas críticas mínimas (handshake fallback)": bloque
  canónico de 8 líneas copiable que el líder envía cuando el asesor no
  responde `ACK-PROTOCOLO`; §4d referencia §4f en vez de "un resumen"
  improvisado.

#### Limpieza D1-D2 + ejemplos sembrados (2026-08-11, verificación external-reviewer #2)

Verificación external-reviewer del ZIP F1-F4: las 6 correcciones correctamente integradas.
Cerrados 2 detalles de limpieza y sembrados ejemplos para el parser del CLI:

- **D1:** §12.8 consolidada en UN solo bloque de reglas (CLAIM/PROCESADO/
  Release/Retry/parser). Se eliminó la repetición del segundo bloque con
  wording distinto que podía confundir sobre cuál era la norma; la regla de
  retry con doble lectura (12.4) se fusionó en el bloque único.
- **D2:** §12.12 alineada — `outbox.md` lista `NACKED` en los estados; la
  línea de `idempotencia-procesados.md` pasa a "log append-only del ciclo de
  vida de cada msg_id (CLAIMED → PROCESADO / SUPERSEDED_BY); dedupe por última
  línea"; `dlq-mensajes.md` menciona el `flag`.
- **Ejemplos sembrados:** `idempotencia-procesados.md` añade una sección
  "Ejemplos de estados (formato v1.6.1 — NO borrar)" con `CLAIMED_BY` y un par
  `CLAIMED_BY` → `SUPERSEDED_BY` para que los tests del CLI futuro puedan
  validar la lógica de "última línea gana" sobre datos reales (no solo
  `PROCESADO`).

Con esto, el ZIP queda como **baseline para la campaña corta de validación**
(T-HS, T-CLAIM, T-RELEASE, T-NACK) y posterior especificación del `cross.ps1`.

---

## Resumen de lo descubierto (prueba de concepto)

Historial de hallazgos por versión (movido desde CROSS_TALK.md el 2026-08-11).

1. El servidor del desktop está en `http://127.0.0.1:PUERTO` con auth básica
   `opencode:$env:OPENCODE_SERVER_PASSWORD`.
2. `POST /session/:id/message` con `parts[].type = "text"` entrega el mensaje
   a esa sesión y lo persiste en su historial.
3. Sin `noReply`, la llamada espera y devuelve la respuesta del agente destino.
4. `POST /session/:id/prompt_async` entrega el mensaje y deja que el agente
   destino lo procese en segundo plano (devuelve `HTTP 204`).
5. Los mensajes quedan guardados: cualquiera de las dos sesiones puede leerlos
   con `GET /session/:id/message`.
6. Para confirmar el crosstalk bidireccional: envía un mensaje con un token
   único, el agente destino responde a la sesión de origen usando el mismo
   mecanismo, y la sesión de origen verifica el token en su historial.
7. Falla con `HTTP 500` solo si el body llega corrupto por quoting de
   PowerShell; la solución es enviarlo desde un archivo con `--data-binary`.
8. Al reiniciar la app cambia el puerto (y puede cambiar el password):
   redetecta y verifica las credenciales al inicio de cada tarea con
   `/global/health`.
9. Para tareas colaborativas, usa rondas con tokens y pide una contribución
   explícita si quieres que la otra sesión trabaje sobre tu propuesta.
10. Los acentos/caracteres especiales pueden llegar como `?` (mojibake):
    envía en ASCII plano y corrige al integrar las respuestas.
11. El "despertado" es automático: enviar SIN `noReply` (o con `prompt_async`)
    hace que el agente destino procese el mensaje solo, sin polling.
    `noReply: true` solo lo deja en el chat sin reacción.
12. **Pitfall principal:** un agente puede responder en SU conversación sin
    enviarlo a la sesión de origen. Verifica la respuesta con su token en TU
    historial; si no aparece, reclama que la envíe por API (sección 5).
13. **Identificar votos:** con N asesores, un token fijo llega repetido y no se
    sabe quién respondió. Cada emisor debe firmar con su ID y su modelo:
    `TOKEN:ses_XXXXXX:modelo` (p. ej. `ACUERDO-FINAL-C1:ses_XXXXXXXX:model-b-v2.5-free`).
    Así se cuenta un acuerdo/cambio por agente, se identifica al autor y el
    usuario humano lee de un vistazo qué modelo respondió (v1.2).
    **El líder comunica a cada integrante su propio ID y su modelo en el mensaje
    de la tarea (sección 4d); los asesores NO deben adivinar su ID deduciéndolo
    de la lista de sesiones** (pitfall real: dos agentes del mismo directorio
    confundieron sus IDs y firmaron tokens con IDs ajenos).
14. **Agentes atascados:** puedes leer cualquier sesión con
    `GET /session/:id/message` para diagnosticar qué pasó (6.1a). Antes de
    intervenir, verifica que la sesión NO crece entre dos lecturas (6.1b): si
    crece, sigue trabajando y no hay que hacer nada. Solo si está quieta,
    despiértalo enviándole `sigue` con `prompt_async` (6.1c).
15. **Validado con 4 asesores (2026-08-10, tarea Buda):** con el líder
    comunicando a cada asesor su propio ID (sección 4d), los 4 tokens
    `MI-CONTRIBUCION-B2` y los 4 `ACUERDO-FINAL-B2` llegaron firmados con el
    ID correcto de cada uno y se contaron 4/4 acuerdos sin ambigüedad. Un
    asesor se atascó dos veces y se recuperó con `sigue` (6.1c), respondiendo
    correctamente al final.
16. **ACK (v1.1):** el token `ACK:<token>:<ID_SESION_EMISORA>:<MODELO_EMISOR>`
    confirma procesamiento (sección 7). Originalmente 30 s de timeout con
    backoff (30/60/120 s) y fallback `sigue`. **SUPERSEDIDO para
    `requiere_ack=true` por §12.3 (120s fijos, sin backoff), v1.6.**
17. **Auditoría (v1.1):** `whiteboard/audit_log.md` registra envíos/recepciones
    con formato pipe `| timestamp | origen | destino | token | tipo | estado | nota |`.
18. **Monitoreo (v1.1):** `GET /session/:id` es el método ligero de presencia;
    `whiteboard/task_status.md` es el tablero global por ronda. Se descartó
    `heartbeat.json` por condiciones de carrera.
19. **Detectar proveedor caído (v1.1):** el último `assistant` vacío creado en
    milisegundos tras el `user` + `time.updated` congelado delatan un fallo de
    proveedor, no un atascamiento. Documentado en 11.5.
20. **Consenso en 3 rondas (v1.1):** las mejoras del protocolo se acordaron con
    3 asesores (model-c, model-b, model-d) usando tokens `MEJORA-R1/R2/R3:<ID>`;
    un proveedor caído (north-mini-code) se excluyó sin bloquear la tarea, y un
    agente (model-d) requirió ayuda explícita para enviar su voto (11.6).
21. **Firma con modelo (v1.2):** el token lleva el sufijo `:<MODELO>` además de
    `:<ID_SESION>` para que el usuario humano identifique el modelo de un vistazo
    (secciones 4d, 5, 7.1). El ID de sesión sigue siendo el identificador canónico.
22. **Monitoreo externo del líder (v1.2):** el líder puede leer la sesión de
    cualquier integrante (`GET /session/:id/message`, 6.1a) y consultar su estado
    (`GET /session/:id`, 10.1). Los agentes lo saben y, si no pueden completar la
    tarea, **escriben un aviso en su propio chat** en texto plano; el líder lo ve
    y les envía ayuda (6.1e, 11.6).
23. **Consenso v1.2 validado (3/3):** los 3 asesores acordaron la v1.2 (tokens
    `ACUERDO-V12:<ID>:<MODELO>`). Aportaron refinamientos menores integrados en
    v1.3: ACK con modelo del emisor al final (7.1), columna MODELO en el log
    (9.1), ejemplo concreto en 4d, error HTTP exacto en el aviso de chat (6.1e)
    y `--aviso-atasco` como mejora futura (apéndice A).
24. **Pitfall firma incompleta (v1.3):** model-b firmó `ACUERDO-V12:-v2.5-free`,
    omitiendo su ID de sesión pese a que se le comunicó. El mensaje se identificó
    por el modelo, pero el ID quedó incompleto. El parseo de tokens debe tolerar
    3 o 4 segmentos (`TOKEN:ID` o `TOKEN:ID:MODELO`), como pidió model-b.
25. **Pitfall BOM en JSON (v1.5, probado 2026-08-10):** generar el payload con
    `[System.Text.Encoding]::UTF8` (con BOM) provoca `HTTP 500 Unexpected
    server error`. Usar UTF-8 sin BOM o ASCII (ver sección 4). Dos envíos a
    model-d fallaron por esto antes de detectarlo.
26. **Descarrilamiento por auto-continuación (v1.5, probado 2026-08-10):** los
    mensajes automáticos "Continue if you have next steps..." hacen que algunos
    asesores (model-d) resuman o cambien de tema en vez de entregar su informe.
    Antídoto: nudge explícito y firme con `prompt_async` indicando qué entregar
    y qué ignorar (ver 6.1c).
27. **Verificación de Ronda 2 validada (v1.5, tarea Bugs TXBridge):** el flujo
    análisis (R1) → verificación (R2, cada asesor responde CONFIRMO/RECHAZO/
    AJUSTO a la lista consolidada del líder) → consenso (R3, voto ACEPTO/
    AJUSTO) cerró una lista de 15 bugs + 4 candidatos con 3/3 firmas OK en
    cada ronda y sin reabrir falsos positivos. La fase R2 detectó una
    inconsistencia del propio líder (outputAtten listado como "funcional" en
    descartados cuando Bug B4 lo tenía como código muerto) → el líder corrigió.
    Pauta: el líder también verifica las afirmaciones de los asesores contra el
    código antes de consolidar.
28. **Identidad del emisor en el mensaje (v1.5, probado 2026-08-10):** model-d
    se quedó bloqueada al no saber a qué sesión responder porque el mensaje de
    la tarea no identificaba al líder emisor. Desde v1.5, el líder incluye en
    el mensaje su propio ID y modelo además de los del destinatario (4d) y los
    asesores piden confirmación si el emisor no está identificado (5, regla 2).
29. **Canal principal = API (v1.5, petición del usuario humano):** la respuesta
    DEBE enviarse a la sesión de origen por API (`prompt_async` o
    `/message`). Escribir solo en el chat propio es un fallo de entrega: el
    emisor no lo ve y debe reclamar (probado con model-b en v1.5). Responder en el
    chat únicamente cuando no exista otra forma de enviar (fallo externo, sin
    herramientas de red) y SIEMPRE avisando al líder. Ver sección 5, regla 1.
30. **Aportes asesores v1.5 (integrados):** model-c (ASCII preferido sobre
    UTF-8 sin BOM en envíos; responder con el mismo token recibido; sección 8.1
    análisis de proyectos grandes), model-d (`prompt_async` como estándar,
    noReply redundante). Confirmados por model-b, model-c y model-d con
    `TOKEN:PROTOCOLO-V15:<ID>:<MODELO>`.
31. **Herramientas con rutas completas (v1.5, pitfall probado):** `python` en
    el PATH es el stub de Windows Store y NO ejecuta; el real está en
    `AppData\Local\Python\pythoncore-3.11-64`. El líder debe indicar las rutas
    completas de las herramientas en la tarea (sección 8.2).
32. **Protocolo anti-sueño v1.6 (2026-08-11):** consenso de 4 asesores
    (model-c, model-d, model-b, model-a) tras 3 rondas. La garantía de wakeup no
    viene de despertar mejor al dormido sino de que el trabajo en vuelo tenga
    dueño con lease expirable, registro durable en un outbox y un scan de
    recuperación que clasifica (RETRY/RESUME/RECONCILE/QUARANTINE) en vez de
    reenviar a ciegas. `prompt_async` sigue siendo la ÚNICA primitiva que
    despierta; los archivos (outbox, escalated, DLQ) son respaldo visible.
    Implementado en la sección 12.
