# SuperAdmin de Nexolu (nexolu-admin + nexolu-admin-front)

Panel web para operar la plataforma sin entrar por SSH a mano. Gestiona
el droplet de SG que orquesta este mismo repo (y, cuando exista, el de
producción) más los datos de negocio de `nexolu-payments-core`. Dos repos
separados, cada uno con su propio deploy y ciclo de vida:

- **`nexolu-admin`** — BFF en FastAPI, sin base de datos propia. Vive en
  **su propio droplet** (`admin.nexolu.co` / API en `api-admin.nexolu.co`),
  **no** en el droplet de SG que orquesta este repo — así apagar o
  destruir SG desde el panel nunca te deja sin el panel que necesitás
  para volver a encenderlo.
- **`nexolu-admin-front`** — SPA en Vue 3, consume exclusivamente el BFF
  de arriba, nunca habla directo con pos-api/payments-core/etc.

## Auth

Login propio, un solo operador (superadmin: `ADMIN_EMAIL` +
`ADMIN_PASSWORD_HASH` en el `.env` de `nexolu-admin`), deliberadamente
desacoplado de cualquier `pos-api` — ver `nexolu-admin/README.md` § Auth.
Si dependiera del pos-api de SG, apagar SG te dejaría sin forma de volver
a entrar al panel que necesitás para encenderlo (bug real, ya corregido).

## Multi-ambiente

Todo endpoint recibe `{env}` en el path (`/v1/admin/infra/sg/status`,
`/v1/admin/payments/sg/merchants`) — hoy `"sg"` es el único ambiente
registrado. Un ambiente sin `droplet_name` configurado (así va a
registrarse `"prod"` cuando exista, hasta tener su propio droplet) no
tiene ninguna capacidad de infraestructura, ni siquiera de solo lectura —
ver `require_infra_capable` en `nexolu-admin/app/core/environments.py`.

## Qué gestiona

### Infraestructura (`/v1/admin/infra/{env}/*`, tab "Infraestructura")

- **Apagar SG**: toma un snapshot y recién después destruye el droplet
  (un droplet apagado normal DigitalOcean lo sigue cobrando igual).
- **Encender SG**: restaura el último snapshot y reasigna la IP
  reservada — **usar siempre este botón, no el dashboard de DigitalOcean
  directo**. Ver `docs/STAGING_SG.md` § 3, por qué importa.
- Snapshots: listar / tomar uno puntual / borrar.
- Métricas (CPU, memoria, load, bandwidth) vía la API de Monitoring de
  DigitalOcean, con botón de refresh manual.
- **Desplegar** un servicio puntual o "todos" — corre `deploy-menu.sh` de
  este mismo repo por SSH. Muestra la rama que está checkeada en cada
  repo del droplet antes de disparar el deploy (`GET /branches`).
- **Variables de entorno**: editar el `.env` de un servicio y recrear su
  contenedor (`docker compose up -d --force-recreate`, nunca `restart` —
  no relee `env_file`) para que tome los valores nuevos. Los que matchean
  un patrón de secreto (password/token/api key/etc.) se muestran
  enmascarados con botón de revelar puntual, nunca en texto plano por
  defecto. Guarda un backup con timestamp del `.env` anterior antes de
  pisarlo.

Servicios que este panel conoce, y cómo se relacionan con este repo:

| Servicio en el panel | Repo | Compose service(s) | `.env` editable |
|---|---|---|---|
| `pos-api` | nexolu-pos-api | pos-web, pos-queue, pos-scheduler | sí |
| `ia-core` | nexolu-ia-core | ia-core | sí |
| `comms-api` | nexolu-comms-api | comms-api | sí |
| `payments-core` | nexolu-payments-core | payments-core | sí |
| `pos-front` | nexolu-pos-front | frontend | sí |
| `infra` | (mysql/redis, este repo) | — | no |

`infra` queda deliberadamente sin editor de `.env`: `MYSQL_ROOT_PASSWORD`/
`MYSQL_APP_PASSWORD` solo se aplican la primera vez que se inicializa el
volumen de datos — cambiarlos con el volumen ya inicializado desincroniza
el `.env` de la contraseña real que MySQL ya tiene, y rompe la conexión
de todos los servicios a la vez.

### Payments (`/v1/admin/payments/{env}/*`, tab "Payments")

- **Comercios**: crear/ver merchants e integrations, regenerar secretos
  de una integration, desactivarla ("eliminar" es soft-delete — conserva
  el historial de transacciones asociado).
- **Wompi**: configurar credenciales sandbox/production por integration,
  ver el webhook URL fijo que `payments-core` expone para ese ambiente
  (`POST /v1/webhooks/wompi`, uno solo, no por merchant), ver/revelar las
  4 llaves (pública, privada, eventos, integridad).
- Ver y editar el `webhook_url` de **salida** de cada integration (el que
  `payments-core` llama para avisarle a la app cliente que un pago se
  confirmó) — es opcional al crear la integration y fácil de olvidar; sin
  él, `payments-core` aprueba el pago pero nunca le avisa a nadie (bug
  real encontrado en vivo el 2026-08-20 contra una transacción real de
  SG, ver `docs/STAGING_SG.md`).
- **Transacciones**: listar con filtros (merchant, estado, provider,
  referencia), ver el estado del último intento de webhook de salida, y
  reenviarlo a mano si quedó pendiente.

## Ver también

- `nexolu-admin/README.md` — arquitectura del BFF, stack, cómo correrlo
  local.
- `nexolu-admin-front/CLAUDE.md` — convenciones del frontend (rutas en
  español, sistema de color, sin librería de UI propia todavía).
- `docs/STAGING_SG.md` — particularidades de cómo está armado el droplet
  de SG que este panel gestiona.
