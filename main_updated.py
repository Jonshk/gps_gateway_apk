from __future__ import annotations

from random import choice

from fastapi import Depends, FastAPI, HTTPException, Query
from fastapi.middleware.cors import CORSMiddleware

from app.config import APP_NAME, ADMIN_PASSWORD
from app.db import init_db
from app.repository import (
    add_position, create_alert, create_vehicle, delete_vehicle,
    get_alerts, get_all_vehicles, get_metrics, get_positions,
    get_vehicle, seed_if_empty, update_vehicle,
)
from app.schemas import AlertCreate, FleetResponse, PositionCreate, VehicleCreate, VehicleUpdate
from app.security import require_write_key
from app.utils import now_iso, random_shift
from app.admin_routes import register_admin_routes, _require_admin
from app.plans_routes import register_plan_routes
from app.webhook_routes import register_webhook_routes, init_webhook_table
from app.gateway_routes import register_gateway_routes, init_gateway_table

app = FastAPI(title=APP_NAME, version="2.3.0")

app.add_middleware(
    CORSMiddleware,
    allow_origins=[
        "https://gpscontrolec.com",
        "https://www.gpscontrolec.com",
        "https://api.gpscontrolec.com",
        "http://localhost:3000",
        "http://127.0.0.1:3000",
        "http://localhost:3001",
    ],
    allow_credentials=True,
    allow_methods=["*"],
    allow_headers=["*"],
)

register_admin_routes(app, lambda: ADMIN_PASSWORD)
register_plan_routes(app, _require_admin)
register_webhook_routes(app, _require_admin)
register_gateway_routes(app, _require_admin)


@app.on_event("startup")
def startup() -> None:
    init_db()
    init_webhook_table()
    init_gateway_table()
    seed_if_empty()


@app.get("/health")
def health():
    return {"ok": True, "service": APP_NAME}


@app.get("/fleet", response_model=FleetResponse)
def fleet():
    vehicles_raw = get_all_vehicles()
    alerts_raw = get_alerts(limit=10)
    metrics = get_metrics()
    vehicles = [{"id": i["id"], "name": i["name"], "status": i["status"],
        "lat": i["lat"], "lng": i["lng"], "speed": i["speed"],
        "geofence": i["geofence"], "updatedAt": i["updated_at"]} for i in vehicles_raw]
    alerts = [{"id": i["id"], "type": i["type"], "message": i["message"],
        "createdAt": i["created_at"], "severity": i["severity"]} for i in alerts_raw]
    return {"vehicles": vehicles, "alerts": alerts, "metrics": metrics}


@app.get("/vehicles")
def list_vehicles():
    return get_all_vehicles()

@app.get("/vehicles/{vehicle_id}")
def read_vehicle(vehicle_id: str):
    v = get_vehicle(vehicle_id)
    if not v:
        raise HTTPException(status_code=404, detail="Vehicle not found")
    return v

@app.post("/vehicles", dependencies=[Depends(require_write_key)])
def create_vehicle_endpoint(payload: VehicleCreate):
    if get_vehicle(payload.id):
        raise HTTPException(status_code=409, detail="Vehicle already exists")
    return create_vehicle(payload.model_dump())

@app.patch("/vehicles/{vehicle_id}", dependencies=[Depends(require_write_key)])
def update_vehicle_endpoint(vehicle_id: str, payload: VehicleUpdate):
    updated = update_vehicle(vehicle_id, payload.model_dump(exclude_unset=True))
    if not updated:
        raise HTTPException(status_code=404, detail="Vehicle not found")
    return updated

@app.delete("/vehicles/{vehicle_id}", dependencies=[Depends(require_write_key)])
def delete_vehicle_endpoint(vehicle_id: str):
    if not delete_vehicle(vehicle_id):
        raise HTTPException(status_code=404, detail="Vehicle not found")
    return {"ok": True}

@app.post("/vehicles/{vehicle_id}/position", dependencies=[Depends(require_write_key)])
def add_position_endpoint(vehicle_id: str, payload: PositionCreate):
    updated = add_position(vehicle_id, payload.lat, payload.lng, payload.speed, payload.geofence)
    if not updated:
        raise HTTPException(status_code=404, detail="Vehicle not found")
    return updated

@app.get("/vehicles/{vehicle_id}/positions")
def list_positions(vehicle_id: str, limit: int = Query(default=20, ge=1, le=500)):
    if not get_vehicle(vehicle_id):
        raise HTTPException(status_code=404, detail="Vehicle not found")
    return get_positions(vehicle_id, limit=limit)

@app.get("/alerts")
def list_alerts(limit: int = Query(default=20, ge=1, le=200)):
    return get_alerts(limit=limit)

@app.post("/alerts", dependencies=[Depends(require_write_key)])
def create_alert_endpoint(payload: AlertCreate):
    return create_alert(payload.model_dump())

@app.post("/simulate/tick", dependencies=[Depends(require_write_key)])
def simulate_tick():
    vehicles = get_all_vehicles()
    moved = []
    for v in vehicles:
        if v["status"] == "offline":
            continue
        lat = random_shift(v["lat"], 0.003 if v["status"] == "active" else 0.0008)
        lng = random_shift(v["lng"], 0.003 if v["status"] == "active" else 0.0008)
        updated = add_position(v["id"], lat, lng,
            v["speed"] if v["status"] == "active" else 0, v.get("geofence"))
        if updated:
            moved.append(updated["id"])
    if moved:
        create_alert({"id": f"sim-{now_iso()}", "type": "movement",
            "message": f"Movimiento detectado en {choice(moved)}", "severity": "medium"})
    return {"ok": True, "moved": moved}
