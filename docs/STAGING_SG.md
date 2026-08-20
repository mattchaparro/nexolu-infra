# Ambiente SG (staging)

El README principal describe el plan de **producción**. El droplet de SG
— gestionado desde el SuperAdmin, ver `docs/ADMIN_PANEL.md` — reusa el
mismo `docker-compose.yml` de este repo, pero difiere en algunos puntos.

## 1. `docker-compose.override.yml` — no commiteado, local a este droplet

Docker Compose lo mezcla automáticamente con `docker-compose.yml`. Hoy
tiene dos ajustes específicos de SG (droplet de 1GB RAM):

- Límites de memoria más chicos para `mysql` (`innodb-buffer-pool-size`,
  `max-connections`, etc.) que los que tendría sentido en producción.
- El servicio **`frontend`** (`nexolu-pos-front`, dominio
  `new-pos-sg.nexolu.co`): todavía no tiene `Dockerfile` propio, así que
  corre como el dev server de Vite directo sobre el código fuente (bind
  mount de `../nexolu-pos-front`), sin build de producción — mismo patrón
  que usa `start_local_pos.sh` en desarrollo local. Cuando exista un
  `Dockerfile` real (multi-stage a nginx, sirviendo estáticos) este
  override se reemplaza por un servicio de verdad en `docker-compose.yml`.

## 2. Dominios

`*-sg.nexolu.co` en vez de `*.nexolu.co` (`api-sg`, `ia-sg`, `comms-sg`,
`payments-sg`, `new-pos-sg`). Los vhosts de nginx para SG se configuran a
mano en el droplet (no viven en este repo, cada ambiente tiene los suyos).

## 3. El droplet se destruye y recrea, no solo se apaga/prende

**"Apagar SG"** desde el panel toma un snapshot y **destruye** el droplet
(uno apagado sin destruir DigitalOcean lo sigue cobrando igual).
**"Encender SG"** restaura el último snapshot como droplet nuevo (id
distinto) y reasigna la IP reservada de DigitalOcean al droplet nuevo —
esa IP reservada es lo único que hace que los dominios `*-sg.nexolu.co` y
el `SSH_HOST` configurado en `nexolu-admin` sigan apuntando al lugar
correcto después de cada ciclo.

**Importa usar siempre esos botones y no apagar/restaurar manualmente
desde el dashboard de DigitalOcean**: un restore manual (o un power-on de
un droplet ya creado por otra vía) no reasigna la IP reservada solo — eso
es un paso que solo ejecuta el código de `nexolu-admin`
(`app/infra/do_client.py:restore_from_latest_snapshot`). Si se salta ese
paso, la IP reservada queda apuntando a lo que apuntaba antes (otro
droplet, o nada) hasta que alguien lo note y la reasigne a mano — pasó en
vivo el 2026-08-20: el panel entero (SSH, deploys, edición de `.env`)
quedó fallando con error de conexión hasta reasignar la IP a mano.

## `pos-front` en SG

Se despliega igual que los demás servicios desde el panel
(`deploy-menu.sh pos-front` — ver más abajo) o eligiendo `pos-front` en
el editor de variables. No tiene `deploy.sh` propio todavía: como corre
sin build (ver punto 1), "desplegar" es solo `git pull` + recrear el
contenedor `frontend` para que el `npm install && npm run dev` de su
`command:` vuelva a correr con el código nuevo.

Igual que los demás repos de servicio, necesita su propia **GitHub Deploy
Key** (SSH, ed25519, dedicada — GitHub no deja reusar la misma clave
pública como Deploy Key en dos repos distintos) autorizada en
`Settings → Deploy keys` de `nexolu-pos-front`, configurada como
`core.sshCommand` del clon en el droplet.

## Deploy manual (sin pasar por el panel)

```bash
ssh root@<host-sg>
cd /opt/nexolu/nexolu-infra
./deploy-menu.sh              # menu interactivo
./deploy-menu.sh pos-front    # o directo, un servicio puntual
```

Ver `docs/ADMIN_PANEL.md` para la tabla completa de servicios que conoce
el panel y cómo se relacionan con los `compose_services` de este repo.
