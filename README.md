# Pulpeando · Punto de venta

Sistema de inventario y punto de venta para tiendas de abarrotes, pequeñas,
medianas y grandes. Multi-negocio, multi-sucursal, con caja que se bloquea
después de cada cobro y funciona sin internet.

- **Base de datos:** Supabase (Postgres 17, RLS, Auth)
- **Aplicación:** HTML + JavaScript, sin compilación ni dependencias
- **Instalable** como PWA en PC, tablet y celular

---

## Qué hay aquí

```
index.html                          POS: catálogo, ticket, cobro, bloqueo por PIN
pedidos.html                        tablero de pedidos en tiempo real
compras.html                        entrada de mercadería y cuentas por pagar
ui.css                              sistema visual: tokens, menú lateral, componentes
menu.js                             menú lateral compartido
escaner.js                          escáner de códigos con la cámara
config.js                           URL y llave pública del proyecto
manifest.webmanifest                para instalar la app
sw.js                               service worker (abre sin internet)
icono-*.png, favicon.ico            iconos de la app instalada

supabase/migrations/                el esquema, en orden
  001_base_abarrotes.sql            catálogo, inventario, lotes, kardex, compras
  002a_rol_repartidor.sql           rol de entregas (va aparte, es un ALTER TYPE)
  002b_caja_y_ventas.sql            cajas, turnos, PIN, ventas, facturación
  003_pedidos_permisos_y_pos.sql    pedidos, permisos de esquema, vistas del POS
  004_endurecer_permisos_de_funciones.sql
  005_revocar_execute_de_public.sql
  006_compras_permisos_y_anulacion.sql
  007_blindaje_de_funciones_nuevas.sql
  008_compras_correcciones.sql
  009_tablero_pedidos.sql
  010_arqueo_y_envio.sql
  011_repartidor_sin_datos_comerciales.sql

sql/
  semilla_inicial.sql               crea el negocio y el primer usuario
  verificar_instalacion.sql         revisa que todo quedó bien instalado
```

---

## Instalación

### 1. Base de datos

En el SQL Editor de Supabase, ejecute los archivos de `supabase/migrations/`
**en orden numérico**, uno por uno. La `002a` va sola a propósito: agrega un
valor a un tipo enum y Postgres no permite usarlo en la misma transacción.

Si usa el CLI de Supabase:

```bash
supabase link --project-ref SU_PROJECT_REF
supabase db push
```

### 2. Comprobar

Ejecute `sql/verificar_instalacion.sql`. Las siete revisiones deben decir
**BIEN**. Si alguna dice RIESGO o FALTA, ahí está el problema.

### 3. Crear el primer usuario

1. Supabase → **Authentication → Users → Add user**
2. Correo y contraseña suyos, marque *Auto Confirm User*
3. Copie el UUID que aparece en la lista
4. Abra `sql/semilla_inicial.sql`, pegue el UUID, cambie el nombre del negocio
   y el PIN, y ejecútelo

Deja creado: la organización, una sucursal, Caja 1, el impuesto ISV 15%,
seis categorías y diez productos de ejemplo.

### 4. Publicar la aplicación

Los cuatro archivos de la raíz van juntos en cualquier hosting estático
(Netlify, Vercel, GitHub Pages, Cloudflare Pages). El service worker y el
manifiesto tienen que quedar al lado de `index.html`.

Con GitHub Pages: Settings → Pages → Deploy from a branch → `main` / `root`.

> Debe servirse por **HTTPS**. Sin HTTPS el navegador no instala la PWA ni
> registra el service worker. `localhost` también sirve para probar.

---

## Cómo funciona la caja

1. El cajero entra con su correo y contraseña
2. Elige caja y abre turno con su PIN de 5 dígitos, declarando el fondo
3. **La caja queda bloqueada.** Para cada venta hay que digitar el PIN
4. Al terminar el cobro se bloquea sola otra vez

La regla no está solo en la pantalla: `fn_registrar_venta` exige un
desbloqueo válido y lo consume. Un desbloqueo sirve para **una** venta y
vence a los 15 minutos. Cinco PINes errados bloquean al cajero por 5 minutos
y cada intento queda registrado en `intentos_pin`.

### Sin internet

El POS sigue vendiendo y guarda las ventas en el navegador (IndexedDB). Al
volver la señal pide el PIN una vez y las envía todas; cada una pasa por su
propio desbloqueo real en el servidor. El PIN nunca se guarda en el
dispositivo.

---

## Roles

| | Auxiliar | Supervisor | Gerente | Repartidor |
|---|---|---|---|---|
| Vender en caja | Sí | Sí | Sí | No |
| Ver costos y márgenes | No | No | Sí | No |
| Anular venta | No | Sí | Sí | No |
| Ajustes de inventario | No | Sí | Sí | No |
| Precios y promociones | No | No | Sí | No |
| Sus entregas | — | — | — | Sí |

Los permisos se aplican en la base de datos con Row Level Security, no
escondiendo botones. Un usuario de un negocio no puede leer datos de otro
aunque llame a la API directamente.

---

## Decisiones de diseño

**Costeo por promedio ponderado**, por producto y sucursal, con lotes aparte
para trazabilidad y vencimientos. Las salidas se valoran al promedio vigente;
la trazabilidad de lote es independiente y usa FEFO: sale primero lo que
vence antes.

**El kardex es inmutable.** No se edita ni se borra: un trigger lo impide.
Las correcciones se hacen con un movimiento contrario, así el inventario
siempre cuadra con su historia.

**El inventario solo se mueve por documento.** Las tablas `kardex`,
`existencias`, `producto_costos` y `ventas` no se pueden escribir
directamente desde la aplicación; solo a través de funciones.

**Los precios los resuelve el servidor.** Ni el POS ni la app del cliente
deciden cuánto cuesta algo: mandan qué y cuánto, y el servidor pone el precio.

**Facturación fiscal con interruptor.** Con
`organizaciones.facturacion_fiscal_activa` en falso el POS emite ticket
interno. En verdadero toma correlativo y CAI del rango autorizado en
`series_fiscales`.

**Un pedido se crea desde los dos lados.** `fn_crear_pedido` atiende tanto al
personal del negocio (mostrador, teléfono, WhatsApp) como al cliente desde su
app, con distinta autorización pero la misma validación de precios.

---

## Sobre las llaves

`config.js` lleva la llave **publishable**, que es pública por diseño: está
hecha para vivir en el navegador y toda la seguridad la impone RLS del lado
del servidor. Es correcto subirla a GitHub.

La llave **service_role** salta todas las políticas de seguridad. Nunca debe
estar en este repositorio ni en ningún archivo que llegue al navegador.

---

## Entrada de mercadería

`compras.html`, para supervisor en adelante. Se busca el producto, se elige
la presentación en que viene (fardo, caja, unidad) y se digita el costo de
esa presentación. La pantalla muestra en vivo cuántas unidades entran, el
costo unitario resultante y **el margen contra el precio de venta actual**,
en rojo si quedaría vendiendo con pérdida.

Se puede guardar como borrador o confirmar. Al confirmar se crean los lotes,
se mueve el kardex y se recalcula el costo promedio. El historial permite
confirmar borradores, abonar a la cuenta por pagar y anular.

Anular una compra confirmada devuelve todo con un movimiento contrario,
valorado **al costo al que entró**, así el costo promedio vuelve exactamente
a donde estaba. Si la mercadería ya se vendió, la anulación falla: primero
hay que resolver las ventas.

## Menú lateral

Un solo menú para todo el sistema, que se acomoda al aparato:

| | |
|---|---|
| **Escritorio** | desplegado; se pliega a solo iconos y recuerda la preferencia |
| **Tablet** | arranca en iconos para dar aire al contenido; se despliega por encima |
| **Celular** | cajón que entra desde la izquierda, con velo y cierre al elegir |

Muestra únicamente los módulos que el rol puede abrir: un auxiliar no ve
Compras. Debajo de los módulos van las secciones propias de cada pantalla:
en la caja son las categorías con su conteo, en compras son las vistas.

## Escáner con la cámara

El botón **Escanear** de la caja y de compras abre la cámara trasera. Usa
`BarcodeDetector`, que ya viene en Chrome de Android y de escritorio; donde
no existe (iPhone, Firefox) carga ZXing por detrás sin que el usuario lo note.

Trabaja en modo continuo: se lee un código tras otro y cada uno se va
agregando, con pitido y vibración, y una lista de lo leído en pantalla.
Incluye linterna en los aparatos que la ofrecen, cambio de cámara si hay
varias, y siempre la opción de digitar el código a mano.

Lee EAN-13, EAN-8, UPC, Code 128, Code 39, ITF, Codabar y QR.

> La cámara **exige HTTPS**. En GitHub Pages funciona; abriendo el archivo
> con doble clic (`file://`) no. El escáner lo detecta y lo explica.

También sigue funcionando el lector de pistola USB: teclea rápido y termina
en Enter, y el buscador lo reconoce por la velocidad de tecleo.

## Tablero de pedidos

`pedidos.html`, para todo el personal de tienda. Cuatro columnas —Nuevos,
Preparando, Listos, En ruta— que se actualizan **solas**: cuando entra un
pedido desde la app del cliente, la tarjeta aparece con campanilla y
vibración, sin recargar nada.

El flujo de una tarjeta: aceptar → ajustar lo que se pudo surtir → marcar
listo → asignar repartidor → cobrar → entregado. En cada paso queda registro
de quién lo hizo y a qué hora.

**Al aceptar un pedido se aparta la mercadería.** La caja deja de poder
venderla mientras el pedido se prepara, así no se despacha algo que ya se
comprometió. La reserva no toca el kardex —nada ha salido todavía— y se
libera al cobrar, al cancelar o al entregar.

**Surtir con faltantes** es lo normal en una pulpería: se ajusta la cantidad
de cada línea, el total se recalcula solo y el cliente ve el monto correcto.

Las tarjetas que llevan más de 20 minutos esperando se marcan en rojo.

## Pendiente

- App del cliente (catálogo, carrito, seguimiento) — la base ya está lista:
  `fn_tiendas_cliente`, `fn_catalogo_cliente`, `fn_crear_pedido`,
  `fn_mis_pedidos`, `fn_cancelar_mi_pedido`
- App del repartidor — la base ya está lista: `fn_mis_entregas`
- Fiado (cuentas por cobrar de los clientes)
- Panel de administración de la plataforma
- Motor de promociones
- Sugerencias de compra por promedio de ventas y tiempo de entrega
- Conteos de inventario y ajustes
