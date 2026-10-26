#!/bin/sh
sh /tmp/pulptest/reset.sh >/dev/null || exit 1
su postgres -c "psql -d pulp -q -f /tmp/pulptest/t_pedidos.sql" >/dev/null 2>&1
su postgres -c "psql -d pulp -f /tmp/pulptest/$1.sql" > /tmp/pulptest/salida_$1.txt 2>&1
echo "salida en /tmp/pulptest/salida_$1.txt ($(wc -l < /tmp/pulptest/salida_$1.txt) lineas)"
