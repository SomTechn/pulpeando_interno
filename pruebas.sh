#!/bin/sh
# Corre todas las pruebas de pantalla.
#
#   ./pruebas.sh            todas
#   ./pruebas.sh consultar  solo esa
#
# Necesita jsdom una sola vez:  npm install jsdom
set -e
cd "$(dirname "$0")"

if [ ! -d node_modules/jsdom ]; then
  echo "Falta jsdom. Corra:  npm install jsdom"
  exit 1
fi

filtro="$1"
total_bien=0
total_mal=0
fallaron=''

for f in *.pruebas.mjs cliente/pruebas.mjs repartidor/pruebas.mjs; do
  [ -f "$f" ] || continue
  case "$f" in *"$filtro"*) ;; *) [ -n "$filtro" ] && continue ;; esac

  salida=$(node "$f" 2>&1) || true
  linea=$(printf '%s\n' "$salida" | grep -E '[0-9]+ bien' | tail -1)
  # Con sed el ".*" de adelante es gloton y se come los digitos: de "225 bien"
  # sacaba 5. grep -o agarra el pedazo entero.
  bien=$(printf '%s' "$linea" | grep -oE '[0-9]+ bien' | grep -oE '^[0-9]+')
  mal=$(printf  '%s' "$linea" | grep -oE '[0-9]+ mal'  | grep -oE '^[0-9]+')
  bien=${bien:-0}; mal=${mal:-0}

  if [ "$mal" -gt 0 ] || [ -z "$linea" ]; then
    fallaron="$fallaron $f"
    printf '%-26s %s\n' "$f" "${linea:-NO CORRIO}"
    printf '%s\n' "$salida" | grep -E '^\s*MAL' || true
  else
    printf '%-26s %s bien\n' "$f" "$bien"
  fi
  total_bien=$((total_bien + bien))
  total_mal=$((total_mal + mal))
done

echo '----------------------------------------'
echo "$total_bien bien · $total_mal mal"
[ -z "$fallaron" ] || { echo "fallaron:$fallaron"; exit 1; }
