# Carta de Porte Virtual / DeCA

Aplicación web en Python para generar, almacenar, descargar y versionar cartas de porte y documentos electrónicos de control administrativo (DeCA).

## Funciones incluidas

- Alta de empresas/intervinientes, orígenes, destinos, conductores y vehículos.
- Distinción expresa entre cargador contractual, transportista efectivo, expedidor y destinatario.
- Creación de borradores y emisión de un PDF nativo digital por transporte.
- PDF con código QR, URL HTTPS única, metadatos de creación/modificación y tamaño máximo controlado de 5 MB.
- Descarga directa del PDF sin autenticación mediante `/d/{token}.pdf`.
- Supabase Postgres para datos y Supabase Storage privado para archivos.
- Versionado: cada modificación genera nuevo PDF, URL y QR, conservando el original.
- Registro de cambios, actor, motivo, fecha, hash SHA-256 y accesos a documentos.
- Enlace móvil para conductor, envío SMS opcional con Twilio y alternativa de WhatsApp.
- Prueba de entrega móvil con receptor, NIF, reservas, geolocalización opcional, foto y firma.
- Conservación mínima de un año con bloqueo de borrado anticipado en base de datos.
- Clave `service_role` sólo en el servidor; nunca se envía al navegador.

## Arquitectura

- Backend y HTML: FastAPI + Jinja2.
- PDF: ReportLab + pypdf.
- QR: qrcode.
- Base de datos y archivos: Supabase.
- Despliegue: Docker. Incluye `render.yaml`, aunque puede desplegarse en cualquier proveedor compatible con contenedores.

## Instalación de Supabase

1. Cree un proyecto en Supabase.
2. Abra **SQL Editor**.
3. Ejecute `sql/001_schema.sql`.
4. Opcionalmente ejecute `sql/002_demo_data.sql`.
5. En **Project Settings > API**, copie:
   - Project URL.
   - `service_role` key. Esta clave debe guardarse exclusivamente como variable secreta del servidor.

El script crea un bucket privado llamado `deca-private`. Si cambia el nombre en `.env`, cambie también el identificador del bucket en el SQL.

## Configuración local

```bash
python -m venv .venv
# Windows
.venv\Scripts\activate
# Linux/macOS
source .venv/bin/activate

pip install -r requirements.txt
copy .env.example .env   # Windows
# cp .env.example .env   # Linux/macOS
```

Edite `.env`:

```env
APP_BASE_URL=http://localhost:8000
SESSION_SECRET=una-clave-muy-larga-y-aleatoria
ADMIN_USERNAME=admin
ADMIN_PASSWORD=una-contrasena-segura
SUPABASE_URL=https://TU-PROYECTO.supabase.co
SUPABASE_SERVICE_ROLE_KEY=TU_SERVICE_ROLE_KEY
SUPABASE_BUCKET=deca-private
```

Arranque:

```bash
uvicorn app.main:app --reload
```

Abra `http://localhost:8000`.

## Despliegue en URL pública

### Opción Docker genérica

```bash
docker build -t carta-porte-virtual .
docker run -p 8000:8000 --env-file .env carta-porte-virtual
```

Configure un dominio HTTPS y establezca `APP_BASE_URL` con la URL pública exacta, por ejemplo:

```env
APP_BASE_URL=https://cartaporte.miempresa.es
```

El QR se genera con esa URL, por lo que debe configurarse antes de emitir documentos reales.

### Render

1. Suba la carpeta a un repositorio privado de GitHub.
2. Cree un Blueprint en Render usando `render.yaml`.
3. Añada las variables secretas solicitadas.
4. Después del primer despliegue, actualice `APP_BASE_URL` con el dominio definitivo y vuelva a desplegar.

## Envío al móvil

Sin proveedor externo, el botón **Enviar al conductor** abre WhatsApp con el texto y los enlaces preparados.

Para envío automático por SMS, configure:

```env
TWILIO_ACCOUNT_SID=...
TWILIO_AUTH_TOKEN=...
TWILIO_FROM_NUMBER=...
```

Para enviar el PDF como archivo adjunto mediante WhatsApp Business se requiere integrar un proveedor autorizado y sus credenciales; el proyecto deja el servicio de notificaciones separado para facilitar esa ampliación.

## Seguridad de producción

La versión inicial utiliza un usuario administrador configurado por variables de entorno. Antes de un despliegue con varios operadores se recomienda:

- Sustituir el acceso único por Supabase Auth o SSO corporativo.
- Añadir roles: administrador, expediciones, transporte, consulta y auditoría.
- Añadir copias de seguridad y alertas de fallo de generación/almacenamiento.
- Establecer una política de privacidad, información RGPD y control del acceso a pruebas de entrega.
- Proteger la aplicación con WAF/rate limiting y registros centralizados.
- No registrar datos de geolocalización salvo que exista base jurídica, información previa y necesidad operativa.

## Correspondencia técnica con requisitos 2026

La Resolución de 5 de junio de 2026 exige, entre otras cuestiones, generación previa al inicio, registro de fecha y hora, PDF nativo digital de hasta 5 MB, QR dentro del PDF, URL HTTPS única, descarga directa sin credenciales y conservación mínima de un año.

Este proyecto implementa esos elementos técnicos. No sustituye una revisión jurídica y operativa: la empresa debe validar los campos, los casos de exclusión, las firmas electrónicas cuando el documento tenga finalidad contractual y sus obligaciones de protección de datos.

Referencias oficiales:

- BOE-A-2026-12784: Resolución de 5 de junio de 2026.
- Orden FOM/2861/2012: documento de control administrativo para transporte público de mercancías.
- Ley 15/2009: contrato de transporte terrestre de mercancías.

## Estructura

```text
app/
  main.py              Rutas y flujos web
  db.py                Acceso server-side a Supabase
  pdf_service.py       Generación PDF y QR
  notifications.py     SMS/WhatsApp
  security.py          Sesión y CSRF
  templates/           Interfaz HTML
  static/              CSS
sql/
  001_schema.sql       Tablas, RLS, retención y bucket
  002_demo_data.sql    Datos opcionales
Dockerfile
render.yaml
```

## Siguiente evolución recomendada

- Firma manuscrita dibujada en pantalla mediante canvas.
- Firma electrónica avanzada AdES mediante prestador cualificado.
- Multiempresa y multiusuario con permisos por organización.
- Importación de expediciones desde Excel/API.
- Agrupación de varios servicios en un mismo DeCA.
- Integración con ERP/TMS y WhatsApp Business API.
- Panel de vencimientos, documentos sin entregar y auditoría exportable.
