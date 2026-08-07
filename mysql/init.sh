#!/bin/bash
# Los .sh en docker-entrypoint-initdb.d SI reciben las env vars del
# contenedor (a diferencia de los .sql, que se ejecutan literales sin
# interpolar nada) - por eso esto es un script y no un .sql plano.
set -e

mysql -uroot -p"${MYSQL_ROOT_PASSWORD}" <<-SQL
    CREATE DATABASE IF NOT EXISTS pos_saas CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci;
    CREATE DATABASE IF NOT EXISTS nexolu_ia_core CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci;
    CREATE DATABASE IF NOT EXISTS nexolu_comms CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci;
    CREATE DATABASE IF NOT EXISTS nexolu_payments_core CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci;

    -- Un solo usuario de aplicacion con permisos sobre las 4 bases -- no
    -- root, pero tampoco un usuario distinto por servicio todavia (mismo
    -- criterio de "no agregar complejidad antes de necesitarla" del
    -- droplet: se puede partir en usuarios separados el dia que haga falta
    -- aislar blast radius).
    CREATE USER IF NOT EXISTS 'nexolu'@'%' IDENTIFIED BY '${MYSQL_APP_PASSWORD}';
    GRANT ALL PRIVILEGES ON pos_saas.* TO 'nexolu'@'%';
    GRANT ALL PRIVILEGES ON nexolu_ia_core.* TO 'nexolu'@'%';
    GRANT ALL PRIVILEGES ON nexolu_comms.* TO 'nexolu'@'%';
    GRANT ALL PRIVILEGES ON nexolu_payments_core.* TO 'nexolu'@'%';
    FLUSH PRIVILEGES;
SQL
