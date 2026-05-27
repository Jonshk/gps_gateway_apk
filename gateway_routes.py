from __future__ import annotations
import json
import uuid
from datetime import datetime
from fastapi import FastAPI, HTTPException, Header
from pydantic import BaseModel
from typing import Optional
from app.db import get_conn
from app.webhook_routes import parse_gps_response, save_message


# ── Schemas ───────────────────────────────────────────────────────────────

class IncomingSmsPayload(BaseModel):
    from_: str
    body: str
    received_at: Optional[str] = None

    class Config:
        populate_by_name = True
        fields = {'from_': {'alias': 'from'}}

class ConfirmPayload(BaseModel):
    command_id: str
    success: bool


# ── DB helpers ────────────────────────────────────────────────────────────

def init_gateway_table() -> None:
    with get_conn() as conn:
        cur = conn.cursor()
        cur.execute("""
            CREATE TABLE IF NOT EXISTS sms_queue (
                id          TEXT PRIMARY KEY,
                to_number   TEXT NOT NULL,
                body        TEXT NOT NULL,
                client_id   TEXT,
                command     TEXT,
                status      TEXT NOT NULL DEFAULT 'pending',
                created_at  TEXT NOT NULL,
                sent_at     TEXT,
                error       TEXT
            )
        """)


def queue_sms(to_number: str, body: str, client_id: str = None, command: str = None) -> str:
    cmd_id = str(uuid.uuid4())
    now = datetime.utcnow().isoformat()
    with get_conn() as conn:
        cur = conn.cursor()
        cur.execute("""
            INSERT INTO sms_queue (id, to_number, body, client_id, command, status, created_at)
            VALUES (%s, %s, %s, %s, %s, 'pending', %s)
        """, (cmd_id, to_number, body, client_id, command, now))
    return cmd_id


def get_pending_commands() -> list[dict]:
    with get_conn() as conn:
        cur = conn.cursor()
        cur.execute("""
            SELECT id, to_number, body, client_id, command
            FROM sms_queue
            WHERE status = 'pending'
            ORDER BY created_at ASC
            LIMIT 10
        """)
        return [dict(r) for r in cur.fetchall()]


def mark_command(command_id: str, success: bool, error: str = None) -> None:
    now = datetime.utcnow().isoformat()
    status = 'sent' if success else 'failed'
    with get_conn() as conn:
        cur = conn.cursor()
        cur.execute("""
            UPDATE sms_queue
            SET status=%s, sent_at=%s, error=%s
            WHERE id=%s
        """, (status, now, error, command_id))


# ── Routes ────────────────────────────────────────────────────────────────

def register_gateway_routes(app: FastAPI, require_admin_fn) -> None:

    def _check_api_key(x_api_key: str | None = Header(default=None)) -> None:
        from app.config import API_WRITE_KEY
        if x_api_key != API_WRITE_KEY:
            raise HTTPException(status_code=401, detail="API key inválida.")

    # ── APK consulta comandos pendientes ──────────────────────────────────
    @app.get("/gateway/pending")
    def gateway_pending(x_api_key: str | None = Header(default=None)):
        """La APK Gateway llama esto cada 10s para ver si hay SMS que enviar."""
        from app.config import API_WRITE_KEY
        if x_api_key != API_WRITE_KEY:
            raise HTTPException(status_code=401, detail="API key inválida.")
        commands = get_pending_commands()
        return [{"id": c["id"], "to": c["to_number"], "body": c["body"]} for c in commands]

    # ── APK confirma que envió el SMS ─────────────────────────────────────
    @app.post("/gateway/confirm")
    def gateway_confirm(
        payload: ConfirmPayload,
        x_api_key: str | None = Header(default=None)
    ):
        """La APK confirma si el SMS fue enviado o falló."""
        from app.config import API_WRITE_KEY
        if x_api_key != API_WRITE_KEY:
            raise HTTPException(status_code=401, detail="API key inválida.")
        mark_command(payload.command_id, payload.success)
        return {"ok": True}

    # ── APK reporta SMS recibido del GPS ──────────────────────────────────
    @app.post("/gateway/incoming")
    def gateway_incoming(
        payload: IncomingSmsPayload,
        x_api_key: str | None = Header(default=None)
    ):
        """La APK reenvía al backend los SMS recibidos del GPS."""
        from app.config import API_WRITE_KEY
        if x_api_key != API_WRITE_KEY:
            raise HTTPException(status_code=401, detail="API key inválida.")
        parsed = parse_gps_response(payload.body)
        save_message(payload.from_, payload.body, parsed)
        return {"ok": True, "parsed_type": parsed.get("parsed_type")}

    # ── Admin encola un comando SMS via gateway ───────────────────────────
    @app.post("/admin/gateway/send")
    def admin_gateway_send(
        payload: dict,
        x_admin_token: str | None = Header(default=None)
    ):
        """
        El panel admin encola un SMS para que la APK lo envíe.
        Body: { client_id, command, to_number, body }
        """
        from app.admin_routes import _admin_sessions
        if not x_admin_token or x_admin_token not in _admin_sessions:
            raise HTTPException(status_code=401, detail="Admin token inválido.")

        to_number = payload.get("to_number")
        body      = payload.get("body")
        client_id = payload.get("client_id")
        command   = payload.get("command")

        if not to_number or not body:
            raise HTTPException(status_code=400, detail="to_number y body son requeridos.")

        cmd_id = queue_sms(to_number, body, client_id, command)
        return {"ok": True, "command_id": cmd_id, "status": "queued"}

    # ── Admin ve el estado de la cola ─────────────────────────────────────
    @app.get("/admin/gateway/queue")
    def gateway_queue(
        x_admin_token: str | None = Header(default=None),
        limit: int = 50
    ):
        """Ver cola de SMS pendientes/enviados."""
        from app.admin_routes import _admin_sessions
        if not x_admin_token or x_admin_token not in _admin_sessions:
            raise HTTPException(status_code=401, detail="Admin token inválido.")
        with get_conn() as conn:
            cur = conn.cursor()
            cur.execute("""
                SELECT * FROM sms_queue
                ORDER BY created_at DESC LIMIT %s
            """, (limit,))
            return [dict(r) for r in cur.fetchall()]

    # ── Admin ve mensajes recibidos del GPS ───────────────────────────────
    @app.get("/admin/gps-messages")
    def list_gps_messages(
        x_admin_token: str | None = Header(default=None),
        limit: int = 50
    ):
        from app.admin_routes import _admin_sessions
        if not x_admin_token or x_admin_token not in _admin_sessions:
            raise HTTPException(status_code=401, detail="Admin token inválido.")
        with get_conn() as conn:
            cur = conn.cursor()
            cur.execute("""
                SELECT * FROM gps_messages
                ORDER BY received_at DESC LIMIT %s
            """, (limit,))
            return [dict(r) for r in cur.fetchall()]

    @app.delete("/admin/gps-messages")
    def clear_gps_messages(x_admin_token: str | None = Header(default=None)):
        from app.admin_routes import _admin_sessions
        if not x_admin_token or x_admin_token not in _admin_sessions:
            raise HTTPException(status_code=401, detail="Admin token inválido.")
        with get_conn() as conn:
            cur = conn.cursor()
            cur.execute("DELETE FROM gps_messages")
        return {"ok": True}
