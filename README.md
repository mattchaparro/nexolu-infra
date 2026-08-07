# Nexolu Infra

Orquestación de despliegue (Docker Compose + nginx + certbot) para todo el
ecosistema Nexolu en **un solo droplet de DigitalOcean**: un motor de base
de datos (MySQL), Docker Compose en vez de Kubernetes, nginx del host +
certbot para TLS — tamaño correcto para un SaaS que recién empieza.

Repos que orquesta (clonados como **hermanos** de este repo en el droplet):

| Repo | Dominio | Puerto interno |
|---|---|---|
| `nexolu-pos-api` | `api.nexolu.co` | 127.0.0.1:8001 |
| `nexolu-ia-core` | `ia.nexolu.co` | 127.0.0.1:8000 |
| `nexolu-comms-api` | `comms.nexolu.co` | 127.0.0.1:8010 |
| `nexolu-payments-core` | `payments.nexolu.co` | 127.0.0.1:8020 |

**`pos.nexolu.co` es del monolito legacy — productivo, nunca apunta a este
droplet.** El POS nuevo vive en `api.nexolu.co`. El frontend nuevo
(`nexolu-pos-front`, todavía no desplegado) usará `new-pos.nexolu.co` — ese
dominio queda reservado para cuando ese repo esté listo, no hay nada que
configurar por ahora.

## Arquitectura

- **Docker Compose** corre MySQL, Redis, y los 4 servicios de aplicación.
  Cada servicio publica su puerto SOLO en `127.0.0.1` — nadie de internet
  les habla directo.
- **nginx corre en el HOST** (no en un contenedor) y es el único proceso
  que escucha en el puerto 80/443 público. Termina TLS y hace reverse
  proxy a `127.0.0.1:<puerto>` de cada servicio.
- **certbot** (plugin `--nginx`) emite y renueva los certificados,
  editando los vhosts de nginx directamente. Un solo `certbot --nginx -d
  <dominio>` por servicio, una sola vez — la renovación automática queda
  instalada sola (`certbot.timer`).
- **`nexolu-ia-core` es público a propósito**: además de `pos-api` (que le
  habla por la red interna de Docker, no por internet), otras apps (spa,
  colegio…) lo van a consumir directo desde afuera — por eso tiene su
  propio dominio (`ia.nexolu.co`), a diferencia del diseño anterior donde
  quedaba solo interno.
- **`git clone` por SSH**, no HTTPS — asume que ya configuraste tu llave
  SSH contra los 4 repos en el droplet (ver `bootstrap.sh`).
- **Cada servicio se despliega de forma independiente**: el `deploy.sh`
  dentro de cada repo (`nexolu-pos-api/deploy.sh`, etc.) hace `git pull` +
  rebuild + restart de SOLO ese servicio — no hace falta bajar todo el
  stack para actualizar uno.

## 1. Provisionar el droplet

- Ubuntu 24.04 LTS, 2 vCPU / 4 GB RAM como piso razonable para los 4
  servicios + MySQL + Redis a este tamaño de operación.
- Apuntar los 4 dominios (`api.nexolu.co`, `ia.nexolu.co`,
  `comms.nexolu.co`, `payments.nexolu.co`) a la IP del droplet (registro
  A) **antes** de correr certbot — falla si el dominio no resuelve
  todavía.

## 2. Primer arranque

```bash
git clone git@github.com:mattchaparro/nexolu-infra.git /opt/nexolu/nexolu-infra
cd /opt/nexolu/nexolu-infra
./bootstrap.sh
```

Instala Docker + nginx + certbot, clona los 4 repos de servicio como
hermanos, instala los vhosts de nginx, y se detiene con instrucciones para
la parte manual (completar los `.env` reales y correr certbot) — ver
`bootstrap.sh` o la sección 3 de abajo.

## 3. Configurar cada `.env`

Cada servicio sigue usando su **propio** `.env` real, copiado de su propio
`.env.example`, exactamente como en desarrollo local — `docker-compose.yml`
solo los referencia (`env_file:`), no los reemplaza.

**`nexolu-pos-api/.env`** — puntos clave para Docker (nombres de host son
los nombres de servicio de `docker-compose.yml`, no `127.0.0.1`):
```
APP_URL=https://api.nexolu.co
DB_HOST=mysql
DB_DATABASE=pos_saas
DB_USERNAME=nexolu
DB_PASSWORD=<el mismo MYSQL_APP_PASSWORD de .env>
REDIS_HOST=redis
IA_CORE_BASE_URL=http://ia-core:8000
COMMS_CORE_BASE_URL=http://comms-api:8000
PAYMENTS_CORE_BASE_URL=http://payments-core:8000
MESSAGING_DRIVER=whatsapp_direct   # cambiar a nexolu_comms cuando se decida el cutover
```
El webhook de WhatsApp en el dashboard de Meta debe apuntar a
`https://api.nexolu.co/api/webhooks/whatsapp` (mientras
`MESSAGING_DRIVER=whatsapp_direct`) o a `https://comms.nexolu.co/webhooks/whatsapp/pos`
(cuando se active `nexolu_comms`) — nunca a `pos.nexolu.co`, ese es el
legacy.

**`nexolu-ia-core/.env`, `nexolu-comms-api/.env`, `nexolu-payments-core/.env`**
```
DATABASE_URL=mysql+aiomysql://nexolu:<MYSQL_APP_PASSWORD>@mysql:3306/<su_base>
```
(`nexolu_ia_core`, `nexolu_comms`, `nexolu_payments_core` respectivamente —
ver `mysql/init.sh`).

Y el `.env` de este repo (infraestructura pura):
```bash
cp .env.example .env   # completar MYSQL_ROOT_PASSWORD y MYSQL_APP_PASSWORD
```

## 4. TLS con certbot

Solo después de que los 4 dominios ya resuelvan a la IP del droplet:
```bash
certbot --nginx -d api.nexolu.co
certbot --nginx -d ia.nexolu.co
certbot --nginx -d comms.nexolu.co
certbot --nginx -d payments.nexolu.co
```
Cada uno edita su vhost en `/etc/nginx/sites-available/` para agregar el
bloque 443 + certificados, y redirige 80→443. La renovación automática
queda instalada sola.

## 5. Levantar todo por primera vez

```bash
docker compose up -d mysql redis
```

Espera a que MySQL esté sano (`docker compose ps`), y carga el esquema de
`pos-api` — **nunca se corre `php artisan migrate`** en este proyecto, el
esquema (85 tablas) viene completo de `database/legacy-schema/schema.sql`:

```bash
docker compose exec -T mysql mysql -unexolu -p<MYSQL_APP_PASSWORD> pos_saas \
  < ../nexolu-pos-api/database/legacy-schema/schema.sql
```

Y despliega los 4 servicios, cada uno con su propio script:

```bash
../nexolu-pos-api/deploy.sh
../nexolu-ia-core/deploy.sh
../nexolu-comms-api/deploy.sh
../nexolu-payments-core/deploy.sh
```

`deploy.sh` de los 3 servicios Python corre `alembic upgrade head` como
parte del deploy — a diferencia de `pos-api`, sus tablas son nuevas y
propias, no un dump heredado.

## 6. Verificar

```bash
docker compose ps
curl -s https://api.nexolu.co/up
curl -s https://ia.nexolu.co/health
curl -s https://comms.nexolu.co/health
curl -s https://payments.nexolu.co/health
docker compose logs -f pos-queue   # confirmar que el worker esta corriendo, no queue:listen
```

## Deploys posteriores (cada servicio, independiente)

Desde CUALQUIER momento en adelante, actualizar un servicio es correr SU
propio script, sin tocar los demás:

```bash
cd /opt/nexolu/nexolu-pos-api && ./deploy.sh
cd /opt/nexolu/nexolu-ia-core && ./deploy.sh
cd /opt/nexolu/nexolu-comms-api && ./deploy.sh
cd /opt/nexolu/nexolu-payments-core && ./deploy.sh
```

Cada uno hace `git pull` + `docker compose build` + `up -d` de solo ese
servicio (y `alembic upgrade head` para los 3 Python) — unos segundos de
downtime por contenedor reiniciado, aceptable a este tamaño de operación.

## Respaldo

Punto único de falla real de este setup: si el droplet se cae, se pierde
la app Y los datos a la vez si no hay respaldo fuera del droplet.

```bash
# Cron diario en el HOST (no en un contenedor), subiendo a DigitalOcean
# Spaces o similar - fuera de alcance de este README, pero no lo saltes.
docker compose exec -T mysql mysqldump -uroot -p<MYSQL_ROOT_PASSWORD> \
  --all-databases > backup-$(date +%F).sql
```

## Qué falta / decisiones pendientes

- **Backups automáticos fuera del droplet** — el comando de arriba es
  manual, falta el cron + subida a almacenamiento externo.
- **Base de datos por servicio con su propio usuario** (en vez de un solo
  `nexolu` compartido) — déjalo para cuando el aislamiento importe más que
  la simplicidad de hoy.
- **`nexolu-pos-front`**: aún no desplegado. Cuando esté listo, agrega su
  propio `deploy.sh` en ese repo y su vhost en `nginx/new-pos.nexolu.co.conf`
  siguiendo el mismo patrón que los demás.
