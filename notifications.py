from __future__ import annotations

import secrets
from typing import Any

from fastapi import HTTPException, Request, status


def is_authenticated(request: Request) -> bool:
    return bool(request.session.get("authenticated"))


def require_admin(request: Request) -> str:
    if not is_authenticated(request):
        raise HTTPException(
            status_code=status.HTTP_303_SEE_OTHER,
            headers={"Location": "/login"},
        )
    return str(request.session.get("username", "admin"))


def get_csrf_token(request: Request) -> str:
    token = request.session.get("csrf_token")
    if not token:
        token = secrets.token_urlsafe(32)
        request.session["csrf_token"] = token
    return str(token)


def verify_csrf(request: Request, submitted: str | None) -> None:
    expected = request.session.get("csrf_token")
    if not expected or not submitted or not secrets.compare_digest(str(expected), submitted):
        raise HTTPException(status_code=403, detail="Token CSRF no válido")


def flash(request: Request, message: str, category: str = "info") -> None:
    request.session["flash"] = {"message": message, "category": category}


def pop_flash(request: Request) -> dict[str, Any] | None:
    return request.session.pop("flash", None)
