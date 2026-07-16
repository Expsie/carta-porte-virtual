from __future__ import annotations

from dataclasses import dataclass
from urllib.parse import quote

import httpx

from .config import settings


@dataclass
class NotificationResult:
    sent: bool
    channel: str
    message: str
    fallback_url: str | None = None


def whatsapp_share_url(phone: str, text: str) -> str:
    normalized = "".join(ch for ch in phone if ch.isdigit())
    return f"https://wa.me/{normalized}?text={quote(text)}"


def send_driver_link(phone: str, text: str) -> NotificationResult:
    """
    Envía un SMS si Twilio está configurado. Si no, devuelve un enlace de
    WhatsApp que el operador puede abrir para compartir el documento.
    """
    fallback = whatsapp_share_url(phone, text)
    if not (
        settings.twilio_account_sid
        and settings.twilio_auth_token
        and settings.twilio_from_number
    ):
        return NotificationResult(
            sent=False,
            channel="whatsapp-link",
            message="Twilio no está configurado; se ha generado un enlace de WhatsApp.",
            fallback_url=fallback,
        )

    endpoint = (
        "https://api.twilio.com/2010-04-01/Accounts/"
        f"{settings.twilio_account_sid}/Messages.json"
    )
    try:
        response = httpx.post(
            endpoint,
            auth=(settings.twilio_account_sid, settings.twilio_auth_token),
            data={
                "From": settings.twilio_from_number,
                "To": phone,
                "Body": text,
            },
            timeout=20,
        )
        response.raise_for_status()
        return NotificationResult(
            sent=True,
            channel="sms",
            message="Enlace enviado por SMS.",
            fallback_url=fallback,
        )
    except Exception as exc:
        return NotificationResult(
            sent=False,
            channel="whatsapp-link",
            message=f"No se pudo enviar el SMS: {exc}",
            fallback_url=fallback,
        )
