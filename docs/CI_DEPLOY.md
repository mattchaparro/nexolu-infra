# Despliegues desde GitHub Actions

Se compila en GitHub y el droplet solo recibe el resultado. Compilar en el
droplet de 2 GB (docker build de la API, vite build de los fronts) lo mandaba
al swap en cada deploy y dejaba a dockerd con ~500 MB entre RAM y swap.

| Repo | Qué hace GitHub | Qué hace el droplet |
|---|---|---|
| nexolu-pos-api | Construye la imagen y la sube a `ghcr.io/mattchaparro/nexolu-pos-api` | `docker pull`, reinicia pos-web/queue/scheduler, migra |
| nexolu-pos-front | `npm run build` | Recibe el `dist/` por SSH y cambia el symlink `current` |
| nexolu-store-front | `npm run build` | Igual que pos-front |

## Cómo se despliega

- **Publicar un release** en GitHub (tag `v1.4.0`): despliega esa versión.
- **Actions → Release → Run workflow**: despliega la rama o tag elegido; la
  versión queda como `sha-1a2b3c4`.
- Cada push a `main` y cada PR solo corren pruebas y build, **no despliegan**.

Volver atrás: lanzar Release a mano sobre el tag anterior. En los fronts
también sirve `./deploy.sh rollback` en el droplet (instantáneo). En la API
las migraciones no se deshacen solas.

Los `deploy.sh` de cada repo siguen funcionando igual para desplegar a mano
desde el droplet.

## Seguridad de la llave

GitHub entra con una llave propia, distinta de las deploy keys de solo
lectura que usa el droplet para `git pull`. En `/root/.ssh/authorized_keys`
va restringida:

```
command="/opt/nexolu/nexolu-infra/scripts/ci-deploy.sh",restrict ssh-ed25519 AAAA... github-actions-deploy
```

Con eso la llave no abre terminal ni túneles: solo puede pedirle a
`scripts/ci-deploy.sh` que despliegue una versión (`pos-api v1.4.0`), y el
script rechaza cualquier otra cosa. Log en `/var/log/nexolu-ci-deploy.log`.

## Activarlo (una sola vez)

1. Mergear las ramas `ci/github-actions` de nexolu-infra, nexolu-pos-api,
   nexolu-pos-front y nexolu-store-front.
2. En el droplet, `git pull` de nexolu-infra, nexolu-pos-front y
   nexolu-store-front (trae `ci-deploy.sh` y el modo `artifact`; no reinicia
   nada).
3. Generar la llave y agregar la línea de arriba a `authorized_keys`.
4. En cada uno de los tres repos, Settings → Environments → `production`:
   - Secretos: `DEPLOY_HOST` (IP del droplet), `DEPLOY_SSH_KEY` (llave
     privada), `DEPLOY_KNOWN_HOSTS` (salida de `ssh-keyscan <ip>`).
   - pos-front: variables `VITE_API_BASE_URL`, `VITE_AUTH_BASE_URL`,
     `VITE_SENTRY_DSN_PUBLIC`, `VITE_SENTRY_TRACES_SAMPLE_RATE`; secretos
     `VITE_PRIMEVUE_LICENSE_KEY`, `SENTRY_AUTH_TOKEN`. Los valores son los
     del `.env` de `/opt/nexolu/nexolu-pos-front`.
   - store-front: variables `VITE_API_BASE_URL`,
     `VITE_PREVIEW_PARENT_ORIGINS` (del `.env` de nexolu-store-front).
5. Primer release de la API: revisar en GitHub → Packages que
   `nexolu-pos-api` quedó **público** (el droplet la descarga sin login). Si
   queda privado, hay que hacer `docker login ghcr.io` en el droplet con un
   token de solo lectura de paquetes.
6. Probar primero con pos-front (se vuelve atrás al instante), después la
   tienda y por último la API.

## Respaldo antes de cada deploy de la API

`ci-deploy.sh` vuelca `pos_saas` a `/opt/respaldos/pre-deploy/<fecha>_<version>/pos_saas.sql.gz`
**antes de reiniciar nada** (unos 3 MB y ~8 s). Si el volcado falla, sale vacío o
hay menos de 2 GB libres, el deploy se aborta y producción queda como estaba.
Se guardan los últimos 7. Para restaurar, sobre una base temporal y nunca
encima de la productiva: `gunzip -c pos_saas.sql.gz | docker exec -i nexolu-mysql-1 mysql ...`.
Es complementario al respaldo de las 03:00 (14 días) y no sale del droplet.

## Costo

nexolu-pos-api y nexolu-pos-front son repos públicos: Actions y los paquetes
de ghcr.io son gratis sin límite. nexolu-store-front es privado: entra en los
2.000 minutos gratis al mes del plan Free, y cada despliegue gasta ~2.
