from __future__ import annotations

import hashlib
import io
from datetime import datetime, timezone
from typing import Any

import qrcode
from pypdf import PdfReader, PdfWriter
from reportlab.lib import colors
from reportlab.lib.enums import TA_CENTER, TA_LEFT
from reportlab.lib.pagesizes import A4
from reportlab.lib.styles import ParagraphStyle, getSampleStyleSheet
from reportlab.lib.units import mm
from reportlab.platypus import (
    Image,
    KeepTogether,
    Paragraph,
    SimpleDocTemplate,
    Spacer,
    Table,
    TableStyle,
)

MAX_PDF_SIZE = 5 * 1024 * 1024


def _text(value: Any, default: str = "No consta") -> str:
    if value is None:
        return default
    value = str(value).strip()
    return value or default


def _status_text(value: Any) -> str:
    statuses = {
        "draft": "BORRADOR",
        "issued": "EMITIDO",
        "in_transit": "EN TRANSPORTE",
        "delivered": "ENTREGADO",
        "cancelled": "ANULADO",
    }
    key = str(value or "").strip().lower()
    return statuses.get(key, _text(value).upper())


def _party(party: dict[str, Any] | None) -> str:
    party = party or {}
    address = ", ".join(
        part
        for part in [
            _text(party.get("address"), ""),
            _text(party.get("postal_code"), ""),
            _text(party.get("city"), ""),
            _text(party.get("province"), ""),
            _text(party.get("country"), ""),
        ]
        if part
    )
    return f"<b>{_text(party.get('name'))}</b><br/>NIF: {_text(party.get('nif'))}<br/>{address}"


def _location(location: dict[str, Any] | None) -> str:
    location = location or {}
    address = ", ".join(
        part
        for part in [
            _text(location.get("address"), ""),
            _text(location.get("postal_code"), ""),
            _text(location.get("city"), ""),
            _text(location.get("province"), ""),
            _text(location.get("country"), ""),
        ]
        if part
    )
    contact = _text(location.get("contact_name"), "")
    phone = _text(location.get("phone"), "")
    extra = " · ".join(part for part in [contact, phone] if part)
    return f"<b>{_text(location.get('name'))}</b><br/>{address}" + (f"<br/>{extra}" if extra else "")


def _pdf_date(value: datetime) -> str:
    utc_value = value.astimezone(timezone.utc)
    return utc_value.strftime("D:%Y%m%d%H%M%SZ")


def build_deca_pdf(
    snapshot: dict[str, Any],
    direct_url: str,
    *,
    created_at: datetime,
    modified_at: datetime,
) -> bytes:
    """Genera un PDF nativo digital con URL y QR únicos."""
    buffer = io.BytesIO()
    styles = getSampleStyleSheet()
    styles.add(
        ParagraphStyle(
            name="TitleCenter",
            parent=styles["Title"],
            fontName="Helvetica-Bold",
            fontSize=17,
            leading=20,
            alignment=TA_CENTER,
            spaceAfter=3 * mm,
        )
    )
    styles.add(
        ParagraphStyle(
            name="Small",
            parent=styles["Normal"],
            fontSize=8,
            leading=10,
            alignment=TA_LEFT,
        )
    )
    styles.add(
        ParagraphStyle(
            name="Cell",
            parent=styles["Normal"],
            fontSize=9,
            leading=11,
            alignment=TA_LEFT,
        )
    )
    styles.add(
        ParagraphStyle(
            name="Section",
            parent=styles["Heading2"],
            fontName="Helvetica-Bold",
            fontSize=11,
            leading=13,
            spaceBefore=3 * mm,
            spaceAfter=1.5 * mm,
        )
    )

    def footer(canvas: Any, doc: Any) -> None:
        canvas.saveState()
        canvas.setFont("Helvetica", 7)
        canvas.drawString(15 * mm, 10 * mm, f"Documento: {_text(snapshot.get('document_number'))}")
        canvas.drawRightString(195 * mm, 10 * mm, f"Página {doc.page}")
        canvas.restoreState()

    document = SimpleDocTemplate(
        buffer,
        pagesize=A4,
        rightMargin=14 * mm,
        leftMargin=14 * mm,
        topMargin=13 * mm,
        bottomMargin=17 * mm,
        title=f"Carta de porte / DeCA {_text(snapshot.get('document_number'))}",
        author=_text(snapshot.get("created_by"), "Aplicación Carta de Porte Virtual"),
        subject="Documento electrónico de control administrativo de transporte",
    )

    qr = qrcode.QRCode(version=None, box_size=7, border=2)
    qr.add_data(direct_url)
    qr.make(fit=True)
    qr_image = qr.make_image(fill_color="black", back_color="white")
    qr_buffer = io.BytesIO()
    qr_image.save(qr_buffer, format="PNG")
    qr_buffer.seek(0)

    title_block = Table(
        [
            [
                Paragraph("CARTA DE PORTE / DeCA", styles["TitleCenter"]),
                Image(qr_buffer, width=31 * mm, height=31 * mm),
            ],
            [
                Paragraph(
                    f"<b>N.º:</b> {_text(snapshot.get('document_number'))}<br/>"
                    f"<b>Versión:</b> {_text(snapshot.get('version'))}<br/>"
                    f"<b>Estado:</b> {_status_text(snapshot.get('status'))}",
                    styles["Cell"],
                ),
                Paragraph("Escanee para descarga directa del PDF", styles["Small"]),
            ],
        ],
        colWidths=[145 * mm, 35 * mm],
    )
    title_block.setStyle(
        TableStyle(
            [
                ("VALIGN", (0, 0), (-1, -1), "MIDDLE"),
                ("BOX", (0, 0), (-1, -1), 0.8, colors.black),
                ("INNERGRID", (0, 0), (-1, -1), 0.25, colors.grey),
                ("BACKGROUND", (0, 0), (0, 0), colors.HexColor("#eef2f7")),
                ("LEFTPADDING", (0, 0), (-1, -1), 7),
                ("RIGHTPADDING", (0, 0), (-1, -1), 7),
                ("TOPPADDING", (0, 0), (-1, -1), 6),
                ("BOTTOMPADDING", (0, 0), (-1, -1), 6),
            ]
        )
    )

    story: list[Any] = [title_block, Spacer(1, 3 * mm)]

    story.append(Paragraph("Intervinientes", styles["Section"]))
    party_data = [
        [
            Paragraph("<b>Cargador contractual</b>", styles["Cell"]),
            Paragraph("<b>Transportista efectivo</b>", styles["Cell"]),
        ],
        [
            Paragraph(_party(snapshot.get("contractual_loader")), styles["Cell"]),
            Paragraph(_party(snapshot.get("effective_carrier")), styles["Cell"]),
        ],
        [
            Paragraph("<b>Expedidor</b>", styles["Cell"]),
            Paragraph("<b>Destinatario</b>", styles["Cell"]),
        ],
        [
            Paragraph(_party(snapshot.get("consignor")), styles["Cell"]),
            Paragraph(_party(snapshot.get("consignee")), styles["Cell"]),
        ],
    ]
    party_table = Table(party_data, colWidths=[90 * mm, 90 * mm])
    party_table.setStyle(
        TableStyle(
            [
                ("BOX", (0, 0), (-1, -1), 0.6, colors.black),
                ("INNERGRID", (0, 0), (-1, -1), 0.3, colors.grey),
                ("BACKGROUND", (0, 0), (-1, 0), colors.HexColor("#eef2f7")),
                ("BACKGROUND", (0, 2), (-1, 2), colors.HexColor("#eef2f7")),
                ("VALIGN", (0, 0), (-1, -1), "TOP"),
                ("PADDING", (0, 0), (-1, -1), 6),
            ]
        )
    )
    story.append(party_table)

    story.append(Paragraph("Servicio de transporte", styles["Section"]))
    service_data = [
        [Paragraph("<b>Origen</b>", styles["Cell"]), Paragraph("<b>Destino</b>", styles["Cell"])],
        [
            Paragraph(_location(snapshot.get("origin")), styles["Cell"]),
            Paragraph(_location(snapshot.get("destination")), styles["Cell"]),
        ],
        [
            Paragraph(f"<b>Fecha del servicio:</b> {_text(snapshot.get('service_date'))}", styles["Cell"]),
            Paragraph(f"<b>Inicio previsto/real:</b> {_text(snapshot.get('service_start_at'))}", styles["Cell"]),
        ],
    ]
    service_table = Table(service_data, colWidths=[90 * mm, 90 * mm])
    service_table.setStyle(
        TableStyle(
            [
                ("BOX", (0, 0), (-1, -1), 0.6, colors.black),
                ("INNERGRID", (0, 0), (-1, -1), 0.3, colors.grey),
                ("BACKGROUND", (0, 0), (-1, 0), colors.HexColor("#eef2f7")),
                ("VALIGN", (0, 0), (-1, -1), "TOP"),
                ("PADDING", (0, 0), (-1, -1), 6),
            ]
        )
    )
    story.append(service_table)

    driver = snapshot.get("driver") or {}
    vehicle = snapshot.get("vehicle") or {}
    story.append(Paragraph("Conductor y vehículo", styles["Section"]))
    driver_vehicle = Table(
        [
            [
                Paragraph(
                    f"<b>Conductor:</b> {_text(driver.get('full_name'))}<br/>"
                    f"<b>NIF:</b> {_text(driver.get('nif'))}<br/>"
                    f"<b>Teléfono:</b> {_text(driver.get('phone'))}",
                    styles["Cell"],
                ),
                Paragraph(
                    f"<b>Matrícula tractora:</b> {_text(vehicle.get('tractor_plate'))}<br/>"
                    f"<b>Remolque/semirremolque:</b> {_text(vehicle.get('trailer_plate'))}<br/>"
                    f"<b>Tipo:</b> {_text(vehicle.get('vehicle_type'))}",
                    styles["Cell"],
                ),
            ]
        ],
        colWidths=[90 * mm, 90 * mm],
    )
    driver_vehicle.setStyle(
        TableStyle(
            [
                ("BOX", (0, 0), (-1, -1), 0.6, colors.black),
                ("INNERGRID", (0, 0), (-1, -1), 0.3, colors.grey),
                ("VALIGN", (0, 0), (-1, -1), "TOP"),
                ("PADDING", (0, 0), (-1, -1), 6),
            ]
        )
    )
    story.append(driver_vehicle)

    story.append(Paragraph("Mercancía", styles["Section"]))
    goods_table = Table(
        [
            [Paragraph("<b>Naturaleza</b>", styles["Cell"]), Paragraph(_text(snapshot.get("goods_nature")), styles["Cell"])],
            [Paragraph("<b>Peso total</b>", styles["Cell"]), Paragraph(f"{_text(snapshot.get('total_weight_kg'))} kg", styles["Cell"])],
            [Paragraph("<b>N.º de bultos</b>", styles["Cell"]), Paragraph(_text(snapshot.get("packages")), styles["Cell"])],
            [Paragraph("<b>Autorización especial</b>", styles["Cell"]), Paragraph(_text(snapshot.get("special_authorization")), styles["Cell"])],
        ],
        colWidths=[50 * mm, 130 * mm],
    )
    goods_table.setStyle(
        TableStyle(
            [
                ("BOX", (0, 0), (-1, -1), 0.6, colors.black),
                ("INNERGRID", (0, 0), (-1, -1), 0.3, colors.grey),
                ("BACKGROUND", (0, 0), (0, -1), colors.HexColor("#eef2f7")),
                ("VALIGN", (0, 0), (-1, -1), "TOP"),
                ("PADDING", (0, 0), (-1, -1), 6),
            ]
        )
    )
    story.append(goods_table)

    story.append(Paragraph("Observaciones, reservas e incidencias", styles["Section"]))
    notes = Table(
        [
            [Paragraph("<b>Observaciones</b>", styles["Cell"]), Paragraph(_text(snapshot.get("observations")), styles["Cell"])],
            [Paragraph("<b>Reservas</b>", styles["Cell"]), Paragraph(_text(snapshot.get("reservations")), styles["Cell"])],
            [Paragraph("<b>Motivo de esta versión</b>", styles["Cell"]), Paragraph(_text(snapshot.get("version_reason")), styles["Cell"])],
        ],
        colWidths=[50 * mm, 130 * mm],
    )
    notes.setStyle(
        TableStyle(
            [
                ("BOX", (0, 0), (-1, -1), 0.6, colors.black),
                ("INNERGRID", (0, 0), (-1, -1), 0.3, colors.grey),
                ("BACKGROUND", (0, 0), (0, -1), colors.HexColor("#eef2f7")),
                ("VALIGN", (0, 0), (-1, -1), "TOP"),
                ("PADDING", (0, 0), (-1, -1), 6),
            ]
        )
    )
    story.append(notes)

    proof = snapshot.get("proof") or {}
    if proof:
        story.append(Paragraph("Prueba de entrega", styles["Section"]))
        delivery_table = Table(
            [
                [Paragraph("<b>Receptor</b>", styles["Cell"]), Paragraph(_text(proof.get("recipient_name")), styles["Cell"])],
                [Paragraph("<b>Identificación</b>", styles["Cell"]), Paragraph(_text(proof.get("recipient_nif")), styles["Cell"])],
                [Paragraph("<b>Fecha/hora de entrega</b>", styles["Cell"]), Paragraph(_text(proof.get("delivered_at")), styles["Cell"])],
                [Paragraph("<b>Reservas en entrega</b>", styles["Cell"]), Paragraph(_text(proof.get("reservations")), styles["Cell"])],
                [Paragraph("<b>Evidencias adjuntas</b>", styles["Cell"]), Paragraph(
                    "Fotografía/PDF: " + ("Sí" if proof.get("proof_storage_path") else "No") +
                    " · Firma en imagen: " + ("Sí" if proof.get("signature_storage_path") else "No"),
                    styles["Cell"],
                )],
            ],
            colWidths=[50 * mm, 130 * mm],
        )
        delivery_table.setStyle(
            TableStyle(
                [
                    ("BOX", (0, 0), (-1, -1), 0.6, colors.black),
                    ("INNERGRID", (0, 0), (-1, -1), 0.3, colors.grey),
                    ("BACKGROUND", (0, 0), (0, -1), colors.HexColor("#eef2f7")),
                    ("VALIGN", (0, 0), (-1, -1), "TOP"),
                    ("PADDING", (0, 0), (-1, -1), 6),
                ]
            )
        )
        story.append(delivery_table)

    story.append(Spacer(1, 4 * mm))
    story.append(
        KeepTogether(
            [
                Paragraph("Verificación y trazabilidad", styles["Section"]),
                Paragraph(
                    f"<b>URL única de descarga:</b> {direct_url}<br/>"
                    f"<b>Creación:</b> {created_at.isoformat()}<br/>"
                    f"<b>Última modificación:</b> {modified_at.isoformat()}<br/>"
                    "El PDF ha sido generado nativamente a partir de datos estructurados. "
                    "Las modificaciones válidas deben realizarse desde el sistema y generar una nueva versión trazable.",
                    styles["Small"],
                ),
            ]
        )
    )

    document.build(story, onFirstPage=footer, onLaterPages=footer)
    raw_pdf = buffer.getvalue()

    reader = PdfReader(io.BytesIO(raw_pdf))
    writer = PdfWriter()
    for page in reader.pages:
        writer.add_page(page)
    writer.add_metadata(
        {
            "/Title": f"Carta de porte / DeCA {_text(snapshot.get('document_number'))}",
            "/Author": _text(snapshot.get("created_by"), "Carta de Porte Virtual"),
            "/Subject": "Documento electrónico de control administrativo de transporte",
            "/Keywords": "DeCA,carta de porte,transporte,QR",
            "/CreationDate": _pdf_date(created_at),
            "/ModDate": _pdf_date(modified_at),
        }
    )
    final_buffer = io.BytesIO()
    writer.write(final_buffer)
    final_pdf = final_buffer.getvalue()

    if len(final_pdf) > MAX_PDF_SIZE:
        raise ValueError("El PDF generado supera el límite normativo de 5 MB")
    return final_pdf


def sha256_hex(content: bytes) -> str:
    return hashlib.sha256(content).hexdigest()
