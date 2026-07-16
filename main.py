from __future__ import annotations

from functools import lru_cache
from typing import Any

from supabase import Client, create_client

from .config import settings


class RepositoryError(RuntimeError):
    pass


def _rows(response: Any) -> list[dict[str, Any]]:
    data = getattr(response, "data", None)
    if data is None:
        return []
    if isinstance(data, list):
        return data
    if isinstance(data, dict):
        return [data]
    return []


class SupabaseRepository:
    def __init__(self, client: Client) -> None:
        self.client = client

    def list_table(self, table: str, *, active_only: bool = False) -> list[dict[str, Any]]:
        query = self.client.table(table).select("*")
        if active_only:
            query = query.eq("active", True)
        response = query.order("created_at", desc=True).execute()
        return _rows(response)

    def get_by_id(self, table: str, item_id: str | None) -> dict[str, Any] | None:
        if not item_id:
            return None
        response = self.client.table(table).select("*").eq("id", item_id).limit(1).execute()
        rows = _rows(response)
        return rows[0] if rows else None

    def insert(self, table: str, payload: dict[str, Any]) -> dict[str, Any]:
        response = self.client.table(table).insert(payload).execute()
        rows = _rows(response)
        if not rows:
            raise RepositoryError(f"Supabase no devolvió el registro insertado en {table}")
        return rows[0]

    def update(self, table: str, item_id: str, payload: dict[str, Any]) -> dict[str, Any]:
        response = self.client.table(table).update(payload).eq("id", item_id).execute()
        rows = _rows(response)
        if not rows:
            raise RepositoryError(f"No se pudo actualizar {table}:{item_id}")
        return rows[0]

    def create_party(self, payload: dict[str, Any]) -> dict[str, Any]:
        return self.insert("parties", payload)

    def create_location(self, payload: dict[str, Any]) -> dict[str, Any]:
        return self.insert("locations", payload)

    def create_driver(self, payload: dict[str, Any]) -> dict[str, Any]:
        return self.insert("drivers", payload)

    def create_vehicle(self, payload: dict[str, Any]) -> dict[str, Any]:
        return self.insert("vehicles", payload)

    def create_shipment(self, payload: dict[str, Any]) -> dict[str, Any]:
        return self.insert("shipments", payload)

    def list_shipments(self, limit: int = 100) -> list[dict[str, Any]]:
        response = (
            self.client.table("shipments")
            .select("*")
            .order("created_at", desc=True)
            .limit(limit)
            .execute()
        )
        shipments = _rows(response)
        location_cache: dict[str, dict[str, Any] | None] = {}
        for shipment in shipments:
            for key, label in (("origin_id", "origin"), ("destination_id", "destination")):
                ref = shipment.get(key)
                if ref not in location_cache:
                    location_cache[ref] = self.get_by_id("locations", ref)
                shipment[label] = location_cache[ref]
        return shipments

    def get_shipment(self, shipment_id: str) -> dict[str, Any] | None:
        return self.get_by_id("shipments", shipment_id)

    def get_shipment_by_pod_token(self, pod_token: str) -> dict[str, Any] | None:
        response = (
            self.client.table("shipments")
            .select("*")
            .eq("pod_token", pod_token)
            .limit(1)
            .execute()
        )
        rows = _rows(response)
        return rows[0] if rows else None

    def get_shipment_full(self, shipment_id: str) -> dict[str, Any] | None:
        shipment = self.get_shipment(shipment_id)
        if not shipment:
            return None
        shipment["contractual_loader"] = self.get_by_id("parties", shipment.get("contractual_loader_id"))
        shipment["effective_carrier"] = self.get_by_id("parties", shipment.get("effective_carrier_id"))
        shipment["consignor"] = self.get_by_id("parties", shipment.get("consignor_id"))
        shipment["consignee"] = self.get_by_id("parties", shipment.get("consignee_id"))
        shipment["origin"] = self.get_by_id("locations", shipment.get("origin_id"))
        shipment["destination"] = self.get_by_id("locations", shipment.get("destination_id"))
        shipment["driver"] = self.get_by_id("drivers", shipment.get("driver_id"))
        shipment["vehicle"] = self.get_by_id("vehicles", shipment.get("vehicle_id"))
        shipment["current_document"] = self.get_by_id(
            "shipment_documents", shipment.get("current_document_id")
        )
        shipment["proof"] = self.get_delivery_proof(shipment_id)
        shipment["events"] = self.list_events(shipment_id)
        return shipment

    def list_events(self, shipment_id: str) -> list[dict[str, Any]]:
        response = (
            self.client.table("shipment_events")
            .select("*")
            .eq("shipment_id", shipment_id)
            .order("created_at", desc=True)
            .execute()
        )
        return _rows(response)

    def add_event(
        self,
        shipment_id: str,
        event_type: str,
        details: dict[str, Any],
        actor: str,
    ) -> dict[str, Any]:
        return self.insert(
            "shipment_events",
            {
                "shipment_id": shipment_id,
                "event_type": event_type,
                "details": details,
                "actor": actor,
            },
        )

    def set_documents_not_current(self, shipment_id: str, *, except_id: str | None = None) -> None:
        query = self.client.table("shipment_documents").update({"is_current": False}).eq(
            "shipment_id", shipment_id
        )
        if except_id:
            query = query.neq("id", except_id)
        query.execute()

    def create_document(self, payload: dict[str, Any]) -> dict[str, Any]:
        return self.insert("shipment_documents", payload)

    def get_document_by_token(self, public_token: str) -> dict[str, Any] | None:
        response = (
            self.client.table("shipment_documents")
            .select("*")
            .eq("public_token", public_token)
            .limit(1)
            .execute()
        )
        rows = _rows(response)
        return rows[0] if rows else None

    def list_documents(self, shipment_id: str) -> list[dict[str, Any]]:
        response = (
            self.client.table("shipment_documents")
            .select("*")
            .eq("shipment_id", shipment_id)
            .order("version", desc=True)
            .execute()
        )
        return _rows(response)

    def upload_bytes(self, path: str, content: bytes, content_type: str) -> None:
        self.client.storage.from_(settings.supabase_bucket).upload(
            path=path,
            file=content,
            file_options={
                "content-type": content_type,
                "cache-control": "3600",
                "upsert": "false",
            },
        )

    def download_bytes(self, path: str) -> bytes:
        result = self.client.storage.from_(settings.supabase_bucket).download(path)
        if isinstance(result, bytes):
            return result
        if hasattr(result, "content"):
            return bytes(result.content)
        return bytes(result)

    def log_access(
        self,
        document_id: str,
        remote_ip: str | None,
        user_agent: str | None,
    ) -> None:
        try:
            self.insert(
                "document_access_logs",
                {
                    "document_id": document_id,
                    "remote_ip": remote_ip,
                    "user_agent": (user_agent or "")[:1000],
                },
            )
        except Exception:
            # Una caída del log no debe impedir una inspección o descarga.
            return

    def get_delivery_proof(self, shipment_id: str) -> dict[str, Any] | None:
        response = (
            self.client.table("delivery_proofs")
            .select("*")
            .eq("shipment_id", shipment_id)
            .limit(1)
            .execute()
        )
        rows = _rows(response)
        return rows[0] if rows else None

    def create_delivery_proof(self, payload: dict[str, Any]) -> dict[str, Any]:
        return self.insert("delivery_proofs", payload)


@lru_cache(maxsize=1)
def get_repository() -> SupabaseRepository:
    settings.validate_runtime()
    client = create_client(settings.supabase_url, settings.supabase_service_role_key)
    return SupabaseRepository(client)
