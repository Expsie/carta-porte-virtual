from __future__ import annotations

import secrets
from datetime import date, datetime, timezone
from pathlib import Path
from typing import Any

from fastapi import FastAPI, File, Form, HTTPException, Request, UploadFile
from fastapi.responses import HTMLResponse, RedirectResponse, Response
from fastapi.staticfiles import StaticFiles
from fastapi.templating import Jinja2Templates
from starlette.middleware.sessions import SessionMiddleware

from .config import settings
from .db import RepositoryError, SupabaseRepository, get_repository
from .notifications import send_driver_link, whatsapp_share_url
from .pdf_service import build_deca_pdf, sha256_hex
from .security import flash, get_csrf_token, is_authenticated, pop_flash, verify_csrf

BASE_DIR = Path(__file__).resolve().parent

app = FastAPI(title=settings.app_name)
app.add_middleware(
    SessionMiddleware,
    secret_key=settings.session_secret,
    same_site="lax",
    https_only=settings.app_base_url.startswith("https://"),
    max_age=8 * 60 * 60,
)
app.mount("/static", StaticFiles(directory=BASE_DIR / "static"), name="static")
templates = Jinja2Templates(directory=str(BASE_DIR / "templates"))


def utcnow() -> datetime:
    return datetime.now(timezone.utc)


def template_context(request: Request, **extra: Any) -> dict[str, Any]:
    context = {
        "request": request,
        "app_name": settings.app_name,
        "authenticated": is_authenticated(request),
        "csrf_token": get_csrf_token(request),
        "flash": pop_flash(request),
        "year": date.today().year,
    }
    context.update(extra)
    return context


def admin_redirect(request: Request) -> RedirectResponse | None:
    if not is_authenticated(request):
        return RedirectResponse("/login", status_code=303)
    return None


def actor(request: Request) -> str:
    return str(request.session.get("username", "admin"))


def parse_number(value: str | None, *, integer: bool = False) -> int | float | None:
    if value is None or not value.strip():
        return None
    normalized = value.strip().replace(".", "").replace(",", ".") if "," in value else value.strip()
    return int(float(normalized)) if integer else float(normalized)


def filename_safe(value: str) -> str:
    return "".join(ch if ch.isalnum() or ch in "-_" else "_" for ch in value)


def serialize_snapshot(full: dict[str, Any], version: int, reason: str, created_by: str) -> dict[str, Any]:
    keys = [
        "id",
        "document_number",
        "status",
        "service_date",
        "service_start_at",
        "service_end_at",
        "goods_nature",
        "total_weight_kg",
        "packages",
        "special_authorization",
        "observations",
        "reservations",
        "created_at",
        "updated_at",
        "issued_at",
        "completed_at",
    ]
    snapshot = {key: full.get(key) for key in keys}
    for key in (
        "contractual_loader",
        "effective_carrier",
        "consignor",
        "consignee",
        "origin",
        "destination",
        "driver",
        "vehicle",
        "proof",
    ):
        snapshot[key] = full.get(key)
    snapshot["version"] = version
    snapshot["version_reason"] = reason
    snapshot["created_by"] = created_by
    return snapshot


def issue_document(
    repo: SupabaseRepository,
    shipment_id: str,
    *,
    reason: str,
    created_by: str,
) -> dict[str, Any]:
    full = repo.get_shipment_full(shipment_id)
    if not full:
        raise HTTPException(status_code=404, detail="Transporte no encontrado")

    version = int(full.get("current_version") or 0) + 1
    public_token = secrets.token_urlsafe(32)
    direct_url = f"{settings.app_base_url}/d/{public_token}.pdf"
    now = utcnow()
    target_status = "issued" if full.get("status") == "draft" else full.get("status")
    snapshot = serialize_snapshot(full, version, reason, created_by)
    snapshot["status"] = target_status
    snapshot["issued_at"] = full.get("issued_at") or now.isoformat()
    snapshot["direct_url"] = direct_url
    pdf_bytes = build_deca_pdf(
        snapshot,
        direct_url,
        created_at=now,
        modified_at=now,
    )
    storage_path = f"documents/{shipment_id}/v{version}_{public_token}.pdf"
    repo.upload_bytes(storage_path, pdf_bytes, "application/pdf")
    document = repo.create_document(
        {
            "shipment_id": shipment_id,
            "version": version,
            "public_token": public_token,
            "storage_path": storage_path,
            "sha256": sha256_hex(pdf_bytes),
            "file_size_bytes": len(pdf_bytes),
            "reason": reason,
            "snapshot": snapshot,
            "created_by": created_by,
            "is_current": True,
        }
    )
    repo.set_documents_not_current(shipment_id, except_id=document["id"])
    new_status = target_status
    repo.update(
        "shipments",
        shipment_id,
        {
            "current_document_id": document["id"],
            "current_version": version,
            "status": new_status,
            "issued_at": full.get("issued_at") or now.isoformat(),
        },
    )
    repo.add_event(
        shipment_id,
        "document_issued",
        {
            "document_id": document["id"],
            "version": version,
            "reason": reason,
            "sha256": document["sha256"],
            "direct_url": direct_url,
        },
        created_by,
    )
    document["direct_url"] = direct_url
    return document


@app.get("/health")
def health() -> dict[str, str]:
    return {"status": "ok"}


@app.get("/login", response_class=HTMLResponse)
def login_page(request: Request) -> HTMLResponse:
    if is_authenticated(request):
        return RedirectResponse("/", status_code=303)
    return templates.TemplateResponse(
        request=request,
        name="login.html",
        context=template_context(request),
    )


@app.post("/login")
def login(
    request: Request,
    username: str = Form(...),
    password: str = Form(...),
    csrf_token: str = Form(...),
) -> RedirectResponse:
    verify_csrf(request, csrf_token)
    valid_user = secrets.compare_digest(username, settings.admin_username)
    valid_password = secrets.compare_digest(password, settings.admin_password)
    if not (valid_user and valid_password):
        flash(request, "Usuario o contraseña incorrectos.", "danger")
        return RedirectResponse("/login", status_code=303)
    request.session.clear()
    request.session["authenticated"] = True
    request.session["username"] = username
    request.session["csrf_token"] = secrets.token_urlsafe(32)
    flash(request, "Sesión iniciada.", "success")
    return RedirectResponse("/", status_code=303)


@app.post("/logout")
def logout(request: Request, csrf_token: str = Form(...)) -> RedirectResponse:
    verify_csrf(request, csrf_token)
    request.session.clear()
    return RedirectResponse("/login", status_code=303)


@app.get("/", response_class=HTMLResponse)
def dashboard(request: Request) -> HTMLResponse:
    redirect = admin_redirect(request)
    if redirect:
        return redirect
    repo = get_repository()
    shipments = repo.list_shipments()
    return templates.TemplateResponse(
        request=request,
        name="dashboard.html",
        context=template_context(request, shipments=shipments),
    )


@app.get("/catalogs", response_class=HTMLResponse)
def catalogs(request: Request) -> HTMLResponse:
    redirect = admin_redirect(request)
    if redirect:
        return redirect
    repo = get_repository()
    return templates.TemplateResponse(
        request=request,
        name="catalogs.html",
        context=template_context(
            request,
            parties=repo.list_table("parties"),
            locations=repo.list_table("locations"),
            drivers=repo.list_table("drivers"),
            vehicles=repo.list_table("vehicles"),
        ),
    )


@app.post("/catalogs/parties")
def add_party(
    request: Request,
    name: str = Form(...),
    nif: str = Form(...),
    address: str = Form(...),
    postal_code: str = Form(""),
    city: str = Form(""),
    province: str = Form(""),
    country: str = Form("España"),
    contact_name: str = Form(""),
    phone: str = Form(""),
    email: str = Form(""),
    notes: str = Form(""),
    csrf_token: str = Form(...),
) -> RedirectResponse:
    redirect = admin_redirect(request)
    if redirect:
        return redirect
    verify_csrf(request, csrf_token)
    get_repository().create_party(
        {
            "name": name.strip(),
            "nif": nif.strip().upper(),
            "address": address.strip(),
            "postal_code": postal_code.strip() or None,
            "city": city.strip() or None,
            "province": province.strip() or None,
            "country": country.strip() or "España",
            "contact_name": contact_name.strip() or None,
            "phone": phone.strip() or None,
            "email": email.strip() or None,
            "notes": notes.strip() or None,
        }
    )
    flash(request, "Empresa dada de alta.", "success")
    return RedirectResponse("/catalogs", status_code=303)


@app.post("/catalogs/locations")
def add_location(
    request: Request,
    name: str = Form(...),
    address: str = Form(...),
    postal_code: str = Form(""),
    city: str = Form(""),
    province: str = Form(""),
    country: str = Form("España"),
    contact_name: str = Form(""),
    phone: str = Form(""),
    email: str = Form(""),
    notes: str = Form(""),
    csrf_token: str = Form(...),
) -> RedirectResponse:
    redirect = admin_redirect(request)
    if redirect:
        return redirect
    verify_csrf(request, csrf_token)
    get_repository().create_location(
        {
            "name": name.strip(),
            "address": address.strip(),
            "postal_code": postal_code.strip() or None,
            "city": city.strip() or None,
            "province": province.strip() or None,
            "country": country.strip() or "España",
            "contact_name": contact_name.strip() or None,
            "phone": phone.strip() or None,
            "email": email.strip() or None,
            "notes": notes.strip() or None,
        }
    )
    flash(request, "Origen/destino dado de alta.", "success")
    return RedirectResponse("/catalogs", status_code=303)


@app.post("/catalogs/drivers")
def add_driver(
    request: Request,
    full_name: str = Form(...),
    nif: str = Form(""),
    phone: str = Form(...),
    email: str = Form(""),
    license_number: str = Form(""),
    notes: str = Form(""),
    csrf_token: str = Form(...),
) -> RedirectResponse:
    redirect = admin_redirect(request)
    if redirect:
        return redirect
    verify_csrf(request, csrf_token)
    get_repository().create_driver(
        {
            "full_name": full_name.strip(),
            "nif": nif.strip().upper() or None,
            "phone": phone.strip(),
            "email": email.strip() or None,
            "license_number": license_number.strip() or None,
            "notes": notes.strip() or None,
        }
    )
    flash(request, "Conductor dado de alta.", "success")
    return RedirectResponse("/catalogs", status_code=303)


@app.post("/catalogs/vehicles")
def add_vehicle(
    request: Request,
    tractor_plate: str = Form(...),
    trailer_plate: str = Form(""),
    vehicle_type: str = Form(""),
    notes: str = Form(""),
    csrf_token: str = Form(...),
) -> RedirectResponse:
    redirect = admin_redirect(request)
    if redirect:
        return redirect
    verify_csrf(request, csrf_token)
    get_repository().create_vehicle(
        {
            "tractor_plate": tractor_plate.strip().upper(),
            "trailer_plate": trailer_plate.strip().upper() or None,
            "vehicle_type": vehicle_type.strip() or None,
            "notes": notes.strip() or None,
        }
    )
    flash(request, "Vehículo dado de alta.", "success")
    return RedirectResponse("/catalogs", status_code=303)


@app.get("/shipments/new", response_class=HTMLResponse)
def new_shipment_page(request: Request) -> HTMLResponse:
    redirect = admin_redirect(request)
    if redirect:
        return redirect
    repo = get_repository()
    return templates.TemplateResponse(
        request=request,
        name="shipment_new.html",
        context=template_context(
            request,
            today=date.today().isoformat(),
            parties=repo.list_table("parties", active_only=True),
            locations=repo.list_table("locations", active_only=True),
            drivers=repo.list_table("drivers", active_only=True),
            vehicles=repo.list_table("vehicles", active_only=True),
        ),
    )


@app.post("/shipments")
def create_shipment(
    request: Request,
    service_date: str = Form(...),
    contractual_loader_id: str = Form(...),
    effective_carrier_id: str = Form(...),
    consignor_id: str = Form(...),
    consignee_id: str = Form(...),
    origin_id: str = Form(...),
    destination_id: str = Form(...),
    driver_id: str = Form(...),
    vehicle_id: str = Form(...),
    goods_nature: str = Form(...),
    total_weight_kg: str = Form(...),
    packages: str = Form(""),
    special_authorization: str = Form(""),
    observations: str = Form(""),
    reservations: str = Form(""),
    csrf_token: str = Form(...),
) -> RedirectResponse:
    redirect = admin_redirect(request)
    if redirect:
        return redirect
    verify_csrf(request, csrf_token)
    repo = get_repository()
    shipment = repo.create_shipment(
        {
            "pod_token": secrets.token_urlsafe(32),
            "service_date": service_date,
            "contractual_loader_id": contractual_loader_id,
            "effective_carrier_id": effective_carrier_id,
            "consignor_id": consignor_id,
            "consignee_id": consignee_id,
            "origin_id": origin_id,
            "destination_id": destination_id,
            "driver_id": driver_id,
            "vehicle_id": vehicle_id,
            "goods_nature": goods_nature.strip(),
            "total_weight_kg": parse_number(total_weight_kg),
            "packages": parse_number(packages, integer=True),
            "special_authorization": special_authorization.strip() or None,
            "observations": observations.strip() or None,
            "reservations": reservations.strip() or None,
            "created_by": actor(request),
        }
    )
    repo.add_event(shipment["id"], "shipment_created", {}, actor(request))
    flash(request, "Borrador creado. Revíselo y pulse Emitir PDF.", "success")
    return RedirectResponse(f"/shipments/{shipment['id']}", status_code=303)


@app.get("/shipments/{shipment_id}", response_class=HTMLResponse)
def shipment_detail(request: Request, shipment_id: str) -> HTMLResponse:
    redirect = admin_redirect(request)
    if redirect:
        return redirect
    repo = get_repository()
    shipment = repo.get_shipment_full(shipment_id)
    if not shipment:
        raise HTTPException(status_code=404, detail="Transporte no encontrado")
    documents = repo.list_documents(shipment_id)
    current_url = None
    if shipment.get("current_document"):
        current_url = f"{settings.app_base_url}/d/{shipment['current_document']['public_token']}.pdf"
    driver = shipment.get("driver") or {}
    message = (
        f"Carta de porte {shipment['document_number']}. Descarga directa: {current_url}"
        if current_url
        else ""
    )
    return templates.TemplateResponse(
        request=request,
        name="shipment_detail.html",
        context=template_context(
            request,
            shipment=shipment,
            documents=documents,
            current_url=current_url,
            delivery_url=f"{settings.app_base_url}/delivery/{shipment['pod_token']}",
            whatsapp_url=whatsapp_share_url(driver.get("phone", ""), message) if message else None,
            parties=repo.list_table("parties", active_only=True),
            locations=repo.list_table("locations", active_only=True),
            drivers=repo.list_table("drivers", active_only=True),
            vehicles=repo.list_table("vehicles", active_only=True),
        ),
    )


@app.post("/shipments/{shipment_id}/issue")
def issue_shipment(
    request: Request,
    shipment_id: str,
    csrf_token: str = Form(...),
) -> RedirectResponse:
    redirect = admin_redirect(request)
    if redirect:
        return redirect
    verify_csrf(request, csrf_token)
    shipment = get_repository().get_shipment(shipment_id)
    if not shipment:
        raise HTTPException(status_code=404, detail="Transporte no encontrado")
    if int(shipment.get("current_version") or 0) > 0:
        flash(request, "El documento ya está emitido. Use Modificar y generar nueva versión.", "warning")
        return RedirectResponse(f"/shipments/{shipment_id}", status_code=303)
    document = issue_document(
        get_repository(),
        shipment_id,
        reason="Emisión inicial",
        created_by=actor(request),
    )
    flash(request, f"PDF versión {document['version']} generado correctamente.", "success")
    return RedirectResponse(f"/shipments/{shipment_id}", status_code=303)


@app.post("/shipments/{shipment_id}/update")
def update_shipment(
    request: Request,
    shipment_id: str,
    reason: str = Form(...),
    service_date: str = Form(...),
    contractual_loader_id: str = Form(...),
    effective_carrier_id: str = Form(...),
    consignor_id: str = Form(...),
    consignee_id: str = Form(...),
    origin_id: str = Form(...),
    destination_id: str = Form(...),
    driver_id: str = Form(...),
    vehicle_id: str = Form(...),
    goods_nature: str = Form(...),
    total_weight_kg: str = Form(...),
    packages: str = Form(""),
    special_authorization: str = Form(""),
    observations: str = Form(""),
    reservations: str = Form(""),
    csrf_token: str = Form(...),
) -> RedirectResponse:
    redirect = admin_redirect(request)
    if redirect:
        return redirect
    verify_csrf(request, csrf_token)
    if not reason.strip():
        raise HTTPException(status_code=400, detail="Debe indicar el motivo del cambio")
    repo = get_repository()
    old = repo.get_shipment(shipment_id)
    if not old:
        raise HTTPException(status_code=404, detail="Transporte no encontrado")
    payload = {
        "service_date": service_date,
        "contractual_loader_id": contractual_loader_id,
        "effective_carrier_id": effective_carrier_id,
        "consignor_id": consignor_id,
        "consignee_id": consignee_id,
        "origin_id": origin_id,
        "destination_id": destination_id,
        "driver_id": driver_id,
        "vehicle_id": vehicle_id,
        "goods_nature": goods_nature.strip(),
        "total_weight_kg": parse_number(total_weight_kg),
        "packages": parse_number(packages, integer=True),
        "special_authorization": special_authorization.strip() or None,
        "observations": observations.strip() or None,
        "reservations": reservations.strip() or None,
    }
    changed = {
        key: {"old": old.get(key), "new": value}
        for key, value in payload.items()
        if str(old.get(key) or "") != str(value or "")
    }
    repo.update("shipments", shipment_id, payload)
    repo.add_event(
        shipment_id,
        "shipment_changed",
        {"reason": reason.strip(), "changes": changed},
        actor(request),
    )
    if int(old.get("current_version") or 0) == 0:
        flash(request, "Cambios guardados en el borrador.", "success")
        return RedirectResponse(f"/shipments/{shipment_id}", status_code=303)
    document = issue_document(
        repo,
        shipment_id,
        reason=reason.strip(),
        created_by=actor(request),
    )
    flash(request, f"Cambios registrados y versión {document['version']} generada.", "success")
    return RedirectResponse(f"/shipments/{shipment_id}", status_code=303)


@app.post("/shipments/{shipment_id}/start")
def start_shipment(
    request: Request,
    shipment_id: str,
    csrf_token: str = Form(...),
) -> RedirectResponse:
    redirect = admin_redirect(request)
    if redirect:
        return redirect
    verify_csrf(request, csrf_token)
    repo = get_repository()
    shipment = repo.get_shipment(shipment_id)
    if not shipment:
        raise HTTPException(status_code=404, detail="Transporte no encontrado")
    if not shipment.get("current_document_id"):
        raise HTTPException(status_code=400, detail="Debe emitir el PDF antes de iniciar el servicio")
    if shipment.get("status") in {"delivered", "cancelled"}:
        raise HTTPException(status_code=400, detail="El transporte no puede iniciarse en su estado actual")
    if shipment.get("status") == "in_transit":
        flash(request, "El servicio ya consta como iniciado.", "warning")
        return RedirectResponse(f"/shipments/{shipment_id}", status_code=303)
    started_at = utcnow()
    repo.update(
        "shipments",
        shipment_id,
        {"status": "in_transit", "service_start_at": started_at.isoformat()},
    )
    repo.add_event(
        shipment_id,
        "service_started",
        {"service_start_at": started_at.isoformat()},
        actor(request),
    )
    document = issue_document(
        repo,
        shipment_id,
        reason="Inicio efectivo del servicio",
        created_by=actor(request),
    )
    flash(
        request,
        f"Servicio iniciado y versión {document['version']} generada. Envíela al conductor.",
        "success",
    )
    return RedirectResponse(f"/shipments/{shipment_id}", status_code=303)


@app.post("/shipments/{shipment_id}/send")
def send_to_driver(
    request: Request,
    shipment_id: str,
    csrf_token: str = Form(...),
) -> RedirectResponse:
    redirect = admin_redirect(request)
    if redirect:
        return redirect
    verify_csrf(request, csrf_token)
    repo = get_repository()
    shipment = repo.get_shipment_full(shipment_id)
    if not shipment or not shipment.get("current_document"):
        raise HTTPException(status_code=400, detail="Primero debe emitir el PDF")
    driver = shipment.get("driver") or {}
    phone = str(driver.get("phone") or "").strip()
    if not phone:
        raise HTTPException(status_code=400, detail="El conductor no tiene teléfono")
    url = f"{settings.app_base_url}/d/{shipment['current_document']['public_token']}.pdf"
    text = (
        f"Carta de porte {shipment['document_number']} (versión {shipment['current_version']}). "
        f"Descarga directa: {url}. Prueba de entrega: "
        f"{settings.app_base_url}/delivery/{shipment['pod_token']}"
    )
    result = send_driver_link(phone, text)
    repo.add_event(
        shipment_id,
        "driver_notification",
        {"channel": result.channel, "sent": result.sent, "message": result.message},
        actor(request),
    )
    if result.sent:
        flash(request, result.message, "success")
        return RedirectResponse(f"/shipments/{shipment_id}", status_code=303)
    if result.fallback_url:
        return RedirectResponse(result.fallback_url, status_code=303)
    flash(request, result.message, "warning")
    return RedirectResponse(f"/shipments/{shipment_id}", status_code=303)


@app.get("/d/{public_token}.pdf")
def direct_download(request: Request, public_token: str) -> Response:
    repo = get_repository()
    document = repo.get_document_by_token(public_token)
    if not document:
        raise HTTPException(status_code=404, detail="Documento no encontrado")
    pdf_bytes = repo.download_bytes(document["storage_path"])
    repo.log_access(
        document["id"],
        request.client.host if request.client else None,
        request.headers.get("user-agent"),
    )
    snapshot = document.get("snapshot") or {}
    name = filename_safe(str(snapshot.get("document_number") or "carta_porte"))
    version = document.get("version") or 1
    return Response(
        content=pdf_bytes,
        media_type="application/pdf",
        headers={
            "Content-Disposition": f'attachment; filename="{name}_v{version}.pdf"',
            "Cache-Control": "no-store, max-age=0",
            "Pragma": "no-cache",
            "X-Content-Type-Options": "nosniff",
        },
    )


@app.get("/delivery/{pod_token}", response_class=HTMLResponse)
def delivery_page(request: Request, pod_token: str) -> HTMLResponse:
    repo = get_repository()
    shipment = repo.get_shipment_by_pod_token(pod_token)
    if not shipment:
        raise HTTPException(status_code=404, detail="Enlace de entrega no válido")
    full = repo.get_shipment_full(shipment["id"])
    current_url = None
    if full and full.get("current_document"):
        current_url = f"{settings.app_base_url}/d/{full['current_document']['public_token']}.pdf"
    return templates.TemplateResponse(
        request=request,
        name="delivery.html",
        context={
            "request": request,
            "app_name": settings.app_name,
            "shipment": full,
            "current_url": current_url,
            "submitted": bool(full and full.get("proof")),
        },
    )


async def save_optional_upload(
    repo: SupabaseRepository,
    upload: UploadFile | None,
    *,
    shipment_id: str,
    prefix: str,
) -> str | None:
    if not upload or not upload.filename:
        return None
    allowed = {"image/jpeg", "image/png", "image/webp", "application/pdf"}
    if upload.content_type not in allowed:
        raise HTTPException(status_code=400, detail="Formato de archivo no admitido")
    content = await upload.read()
    if not content:
        return None
    if len(content) > 5 * 1024 * 1024:
        raise HTTPException(status_code=400, detail="El archivo supera 5 MB")
    extension = Path(upload.filename).suffix.lower() or ".bin"
    path = f"proofs/{shipment_id}/{prefix}_{secrets.token_hex(12)}{extension}"
    repo.upload_bytes(path, content, upload.content_type or "application/octet-stream")
    return path


@app.post("/delivery/{pod_token}")
async def submit_delivery(
    request: Request,
    pod_token: str,
    recipient_name: str = Form(...),
    recipient_nif: str = Form(""),
    reservations: str = Form(""),
    latitude: str = Form(""),
    longitude: str = Form(""),
    proof_file: UploadFile | None = File(None),
    signature_file: UploadFile | None = File(None),
) -> RedirectResponse:
    repo = get_repository()
    shipment = repo.get_shipment_by_pod_token(pod_token)
    if not shipment:
        raise HTTPException(status_code=404, detail="Enlace de entrega no válido")
    if not shipment.get("current_document_id"):
        raise HTTPException(status_code=400, detail="La carta de porte todavía no ha sido emitida")
    if repo.get_delivery_proof(shipment["id"]):
        return RedirectResponse(f"/delivery/{pod_token}", status_code=303)

    proof_path = await save_optional_upload(
        repo, proof_file, shipment_id=shipment["id"], prefix="proof"
    )
    signature_path = await save_optional_upload(
        repo, signature_file, shipment_id=shipment["id"], prefix="signature"
    )
    delivered_at = utcnow()
    repo.create_delivery_proof(
        {
            "shipment_id": shipment["id"],
            "recipient_name": recipient_name.strip(),
            "recipient_nif": recipient_nif.strip().upper() or None,
            "reservations": reservations.strip() or None,
            "proof_storage_path": proof_path,
            "signature_storage_path": signature_path,
            "latitude": parse_number(latitude),
            "longitude": parse_number(longitude),
            "delivered_at": delivered_at.isoformat(),
            "submitted_ip": request.client.host if request.client else None,
            "submitted_user_agent": (request.headers.get("user-agent") or "")[:1000],
        }
    )
    repo.update(
        "shipments",
        shipment["id"],
        {
            "status": "delivered",
            "completed_at": delivered_at.isoformat(),
            "reservations": reservations.strip() or shipment.get("reservations"),
        },
    )
    repo.add_event(
        shipment["id"],
        "delivery_proof_submitted",
        {
            "recipient_name": recipient_name.strip(),
            "recipient_nif": recipient_nif.strip().upper() or None,
            "reservations": reservations.strip() or None,
            "proof_storage_path": proof_path,
            "signature_storage_path": signature_path,
        },
        "entrega-movil",
    )
    issue_document(
        repo,
        shipment["id"],
        reason="Prueba de entrega y reservas del destinatario",
        created_by="entrega-movil",
    )
    return RedirectResponse(f"/delivery/{pod_token}", status_code=303)


@app.exception_handler(RepositoryError)
def repository_error(request: Request, exc: RepositoryError) -> HTMLResponse:
    return templates.TemplateResponse(
        request=request,
        name="error.html",
        context={"request": request, "app_name": settings.app_name, "message": str(exc)},
        status_code=500,
    )
