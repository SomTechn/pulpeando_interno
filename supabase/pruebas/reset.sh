#!/bin/sh
su postgres -c "dropdb --if-exists pulp" 
su postgres -c "createdb pulp"
for f in shim 001_base_abarrotes 002a_rol_repartidor 002b_caja_y_ventas 003_pedidos_permisos_y_pos 004_endurecer_permisos_de_funciones 005_revocar_execute_de_public 006_compras_permisos_y_anulacion 007_blindaje_de_funciones_nuevas 008_compras_correcciones 009_tablero_pedidos 010_arqueo_y_envio 011_repartidor_sin_datos_comerciales 012_fiado 013_clientes_blindaje 014_pedidos_del_cliente 015_numero_por_sucursal 016_pedir_como_cliente 017_historial_de_ventas 018_conteo_de_inventario 019_ubicaciones_y_consulta 020_ajustes_con_aprobacion 021_historial_de_conteos 022_merma 023_auditoria_de_bodega 024_bodega_desde_consulta 025_inventario_por_fecha 026_control_de_inventario 027_producto_desde_compras 028_sugerencias_de_compra 029_app_del_repartidor 030_ticket_y_configuracion_fiscal 031_dias_de_pago 032_devoluciones_parciales 033_gaveta 034_entrada_de_caja 036_denominaciones 037_un_cajero_una_caja 038_imagenes_del_negocio; do
  su postgres -c "psql -d pulp -q -v ON_ERROR_STOP=1 -f /tmp/pulptest/$f.sql" >/dev/null 2>&1 || { echo "FALLO $f"; exit 1; }
done
echo "db lista"
