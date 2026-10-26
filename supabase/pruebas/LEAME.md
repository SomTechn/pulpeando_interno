# Pruebas de la base, por rol

Cada suite levanta datos de ejemplo y después se hace pasar por cada usuario
—auxiliar, supervisor, gerente, el de la otra pulpería, y `anon`— para
comprobar que cada quien puede hacer exactamente lo suyo y nada más.

No corren contra Supabase: corren contra un Postgres local. `shim.sql` finge
lo poco que las migraciones necesitan de Supabase (el esquema `auth`, `auth.uid()`
leyendo de una variable de sesión, los roles `authenticated` y `anon`), así que
`set request.jwt.claim.sub = '<id>'` es «ahora soy esta persona».

## Correr

    sh reset.sh            # borra y vuelve a aplicar todas las migraciones
    sh correr.sh t_gaveta  # reset + semilla + la suite, deja salida_t_gaveta.txt

Necesita un Postgres con `pgcrypto`, y la carpeta de migraciones al lado.
`reset.sh` lleva la lista de migraciones en orden: **al agregar una migración
nueva hay que agregarla ahí**.

## Cómo se leen

No hay framework. Cada bloque imprime lo que pasó y debajo una línea
`--- esperado: ... ---` que dice qué tenía que pasar. Los `ERROR:` que salen
son casi todos a propósito: la mitad de las pruebas son que algo **no** se
pueda. Un error sin su línea de `esperado` cerca es el que hay que mirar.
