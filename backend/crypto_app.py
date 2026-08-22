"""SIH 26183 cryptocurrency investigation API.

Run with:
    flask --app crypto_app run --debug

The API is intentionally kept separate from the existing disaster-relief app.py.
It uses the SIH 26183 database schema under database/crypto/ and the contract in
API_CONTRACT.md.
"""

from __future__ import annotations

import os
import re
from decimal import Decimal
from functools import wraps
from typing import Any
from uuid import UUID

from dotenv import load_dotenv
from flask import Flask, jsonify, request
from flask_cors import CORS
from supabase import Client, create_client

load_dotenv()

app = Flask(__name__)
CORS(app, resources={r"/api/*": {"origins": "*"}})

SUPABASE_URL = os.getenv("SUPABASE_URL")
SUPABASE_KEY = os.getenv("SUPABASE_KEY")

if not SUPABASE_URL or not SUPABASE_KEY:
    raise RuntimeError("SUPABASE_URL and SUPABASE_KEY must be configured in backend/.env")

supabase: Client = create_client(SUPABASE_URL, SUPABASE_KEY)

SUPPORTED_CHAINS = {"ethereum"}
WALLET_TYPES = {"reported_wallet", "intermediary", "exchange", "vasp", "unknown"}
RISK_LEVELS = {"low", "medium", "high", "critical"}
TX_STATUSES = {"pending", "confirmed", "failed", "unknown"}
MATCH_TYPES = {"known_address", "entity_label", "behavioral_match", "cluster_match", "unknown"}
ENTITY_TYPES = {"vasp", "exchange", "bridge", "defi_protocol", "unknown"}
SEVERITIES = {"low", "medium", "high", "critical"}
ETH_ADDRESS = re.compile(r"^0x[a-fA-F0-9]{40}$")


def ok(data: Any, status: int = 200):
    return jsonify({"success": True, "data": data, "error": None}), status


def fail(code: str, message: str, status: int = 400):
    return jsonify({"success": False, "data": None, "error": {"code": code, "message": message}}), status


def db_error(exc: Exception):
    return fail("DATABASE_ERROR", "A database operation failed.", 500)


def parse_json(required_fields: list[str]):
    body = request.get_json(silent=True)
    if not isinstance(body, dict):
        return None, fail("VALIDATION_ERROR", "Request body must be a JSON object.")
    missing = [field for field in required_fields if field not in body]
    if missing:
        return None, fail("MISSING_FIELD", f"Required field(s) missing: {', '.join(missing)}")
    return body, None


def valid_uuid(value: Any) -> bool:
    try:
        UUID(str(value))
        return True
    except (ValueError, TypeError, AttributeError):
        return False


def validate_wallet(address: Any, chain: Any):
    if not isinstance(address, str) or not address.strip():
        return False, "The wallet address is required."
    if chain not in SUPPORTED_CHAINS:
        return False, "The selected blockchain is not supported."
    if chain == "ethereum" and not ETH_ADDRESS.fullmatch(address.strip()):
        return False, "The wallet address is invalid for the selected blockchain."
    return True, None


def serialize_value(value: Any):
    if isinstance(value, Decimal):
        return format(value, "f")
    if isinstance(value, UUID):
        return str(value)
    return value


def serialize_row(row: dict[str, Any]):
    return {key: serialize_value(value) for key, value in row.items()}


def fetch_one(table: str, column: str, value: Any):
    response = supabase.table(table).select("*").eq(column, value).limit(1).execute()
    return response.data[0] if response.data else None


def case_exists(case_id: str):
    if not valid_uuid(case_id):
        return None
    return fetch_one("cases", "id", case_id)


def ensure_case_wallet(case_id: str, wallet_id: str, wallet_type: str):
    supabase.table("case_wallets").upsert(
        {"case_id": case_id, "wallet_id": wallet_id, "type": wallet_type},
        on_conflict="case_id,wallet_id",
    ).execute()


def risk_level(score: int) -> str:
    if score >= 90:
        return "critical"
    if score >= 70:
        return "high"
    if score >= 40:
        return "medium"
    return "low"


def build_risk(case_id: str):
    transactions = (
        supabase.table("case_transactions")
        .select("hop, transactions(id, transaction_hash, timestamp, amount, from_wallet_id, to_wallet_id)")
        .eq("case_id", case_id)
        .execute()
        .data
        or []
    )
    attributions = supabase.table("attributions").select("id").eq("case_id", case_id).execute().data or []

    hops = [int(row.get("hop") or 0) for row in transactions]
    score = 0
    indicators = []

    if max(hops, default=0) >= 2:
        score += 30
        indicators.append({
            "code": "MULTI_HOP",
            "description": "Funds moved through multiple intermediary wallets",
            "severity": "medium",
            "evidence": [f"Maximum observed hop: {max(hops)}"],
        })

    if len(transactions) >= 2:
        timestamps = [row.get("transactions", {}).get("timestamp") for row in transactions if row.get("transactions")]
        timestamps = [x for x in timestamps if x]
        if len(timestamps) >= 2:
            score += 25
            indicators.append({
                "code": "RAPID_MOVEMENT",
                "description": "Funds moved rapidly between addresses",
                "severity": "high",
                "evidence": ["Multiple case transactions were observed"],
            })

    if attributions:
        score += 35
        indicators.append({
            "code": "VASP_INTERACTION",
            "description": "Funds reached a wallet associated with a VASP",
            "severity": "high",
            "evidence": [f"{len(attributions)} attribution result(s) associated with this case"],
        })

    score = min(score, 100)
    level = risk_level(score)

    existing = supabase.table("risk_assessments").select("*").eq("case_id", case_id).order("created_at", desc=True).limit(1).execute().data or []
    if existing:
        assessment = existing[0]
        supabase.table("risk_assessments").update({"score": score, "level": level}).eq("id", assessment["id"]).execute()
        assessment["score"] = score
        assessment["level"] = level
        assessment_id = assessment["id"]
        supabase.table("risk_indicators").delete().eq("risk_assessment_id", assessment_id).execute()
    else:
        assessment = supabase.table("risk_assessments").insert({"case_id": case_id, "score": score, "level": level}).execute().data[0]
        assessment_id = assessment["id"]

    for indicator in indicators:
        supabase.table("risk_indicators").insert({
            "risk_assessment_id": assessment_id,
            "code": indicator["code"],
            "description": indicator["description"],
            "severity": indicator["severity"],
            "evidence": indicator["evidence"],
        }).execute()

    return assessment


@app.get("/api/health")
def health():
    try:
        supabase.table("cases").select("id").limit(1).execute()
        return ok({"status": "healthy", "database": "connected", "chain": "ethereum"})
    except Exception as exc:
        return fail("DATABASE_ERROR", "Database connection failed.", 500)


@app.post("/api/cases")
def create_case():
    body, error = parse_json(["case_reference", "fraud_type"])
    if error:
        return error
    if not isinstance(body["case_reference"], str) or not body["case_reference"].strip():
        return fail("VALIDATION_ERROR", "case_reference must be a non-empty string.")
    if not isinstance(body["fraud_type"], str) or not body["fraud_type"].strip():
        return fail("VALIDATION_ERROR", "fraud_type must be a non-empty string.")
    try:
        data = supabase.table("cases").insert({
            "case_reference": body["case_reference"].strip(),
            "fraud_type": body["fraud_type"].strip(),
            "description": body.get("description"),
        }).execute().data[0]
        return ok(serialize_row(data), 201)
    except Exception as exc:
        message = str(exc).lower()
        if "duplicate" in message or "unique" in message:
            return fail("VALIDATION_ERROR", "case_reference already exists.", 400)
        return db_error(exc)


@app.get("/api/cases/<case_id>")
def get_case(case_id: str):
    if not valid_uuid(case_id):
        return fail("CASE_NOT_FOUND", "Case does not exist.", 404)
    try:
        data = fetch_one("cases", "id", case_id)
        if not data:
            return fail("CASE_NOT_FOUND", "Case does not exist.", 404)
        return ok(serialize_row(data))
    except Exception as exc:
        return db_error(exc)


@app.post("/api/investigations/analyze")
def analyze():
    body, error = parse_json(["case_id", "wallet_address", "chain"])
    if error:
        return error
    case_id = body["case_id"]
    if not valid_uuid(case_id):
        return fail("CASE_NOT_FOUND", "Case does not exist.", 404)
    try:
        if not case_exists(case_id):
            return fail("CASE_NOT_FOUND", "Case does not exist.", 404)
        valid, message = validate_wallet(body["wallet_address"], body["chain"])
        if not valid:
            return fail("UNSUPPORTED_CHAIN" if body["chain"] not in SUPPORTED_CHAINS else "INVALID_WALLET_ADDRESS", message, 400)

        address = body["wallet_address"].strip()
        wallet = fetch_one("wallets", "address", address)
        if wallet and wallet["chain"] != body["chain"]:
            wallet = None
        if not wallet:
            wallet = supabase.table("wallets").insert({
                "address": address,
                "chain": body["chain"],
                "type": "reported_wallet",
            }).execute().data[0]
        else:
            supabase.table("wallets").update({"type": "reported_wallet"}).eq("id", wallet["id"]).execute()
            wallet["type"] = "reported_wallet"

        ensure_case_wallet(case_id, wallet["id"], "reported_wallet")

        # Provider adapters should populate transactions before/around this endpoint.
        # The MVP API reads normalized transactions from the database, never provider-shaped data.
        case_tx = supabase.table("case_transactions").select("transaction_id, hop").eq("case_id", case_id).execute().data or []
        tx_count = len(case_tx)
        max_hop = max([int(x.get("hop") or 0) for x in case_tx], default=0)

        tx_rows = []
        for link in case_tx:
            tx = fetch_one("transactions", "id", link["transaction_id"])
            if tx:
                tx_rows.append(tx)
        total = sum((Decimal(str(x["amount"])) for x in tx_rows), Decimal("0"))

        risk = build_risk(case_id)
        attribution_rows = supabase.table("attributions").select("*, entities(name, type)").eq("case_id", case_id).order("confidence", desc=True).limit(1).execute().data or []
        attribution = attribution_rows[0] if attribution_rows else None

        response = {
            "case_id": case_id,
            "wallet": {
                "id": str(wallet["id"]),
                "address": wallet["address"],
                "chain": wallet["chain"],
                "type": wallet["type"],
            },
            "analysis": {
                "status": "completed",
                "transaction_count": tx_count,
                "hop_count": max_hop,
                "total_transferred_value": format(total, "f"),
            },
            "risk": {"score": risk["score"], "level": risk["level"]},
            "attribution": None,
        }
        if attribution:
            response["attribution"] = {
                "entity_name": attribution.get("entities", {}).get("name"),
                "entity_type": attribution.get("entities", {}).get("type"),
                "confidence": float(attribution["confidence"]),
            }
        return ok(response)
    except Exception as exc:
        return db_error(exc)


@app.get("/api/cases/<case_id>/transactions")
def get_transactions(case_id: str):
    if not valid_uuid(case_id) or not case_exists(case_id):
        return fail("CASE_NOT_FOUND", "Case does not exist.", 404)
    try:
        page = max(int(request.args.get("page", 1)), 1)
        limit = min(max(int(request.args.get("limit", 50)), 1), 200)
        offset = (page - 1) * limit
        links = supabase.table("case_transactions").select("transaction_id, hop", count="exact").eq("case_id", case_id).range(offset, offset + limit - 1).execute()
        transactions = []
        for link in links.data or []:
            tx = fetch_one("transactions", "id", link["transaction_id"])
            if tx:
                tx["hop"] = link["hop"]
                tx["from_address"] = fetch_one("wallets", "id", tx["from_wallet_id"])["address"]
                tx["to_address"] = fetch_one("wallets", "id", tx["to_wallet_id"])["address"]
                tx.pop("from_wallet_id", None)
                tx.pop("to_wallet_id", None)
                tx.pop("created_at", None)
                transactions.append(serialize_row(tx))
        total = links.count or 0
        return ok({"transactions": transactions, "pagination": {"page": page, "limit": limit, "total": total}})
    except Exception as exc:
        return db_error(exc)


@app.get("/api/cases/<case_id>/graph")
def get_graph(case_id: str):
    if not valid_uuid(case_id) or not case_exists(case_id):
        return fail("CASE_NOT_FOUND", "Case does not exist.", 404)
    try:
        wallet_links = supabase.table("case_wallets").select("wallet_id, type").eq("case_id", case_id).execute().data or []
        node_ids = {x["wallet_id"] for x in wallet_links}
        types = {x["wallet_id"]: x["type"] for x in wallet_links}
        nodes = []
        for wallet_id in node_ids:
            wallet = fetch_one("wallets", "id", wallet_id)
            if wallet:
                nodes.append({"id": str(wallet["id"]), "address": wallet["address"], "type": types.get(wallet_id, wallet["type"]), "label": "Reported Wallet" if types.get(wallet_id) == "reported_wallet" else "Potential VASP" if types.get(wallet_id) == "vasp" else "Intermediary Wallet" if types.get(wallet_id) == "intermediary" else "Wallet"})

        links = supabase.table("case_transactions").select("transaction_id, hop").eq("case_id", case_id).execute().data or []
        edges = []
        for link in links:
            tx = fetch_one("transactions", "id", link["transaction_id"])
            if not tx:
                continue
            edges.append({"id": str(tx["id"]), "source": str(tx["from_wallet_id"]), "target": str(tx["to_wallet_id"]), "transaction_hash": tx["transaction_hash"], "amount": serialize_value(tx["amount"]), "asset": tx["asset"], "timestamp": tx["timestamp"], "hop": link["hop"]})
        return ok({"nodes": nodes, "edges": edges})
    except Exception as exc:
        return db_error(exc)


@app.get("/api/cases/<case_id>/attribution")
def get_attribution(case_id: str):
    if not valid_uuid(case_id) or not case_exists(case_id):
        return fail("CASE_NOT_FOUND", "Case does not exist.", 404)
    try:
        rows = supabase.table("attributions").select("id, wallet_id, entity_id, match_type, confidence, evidence, created_at, wallets(address), entities(name, type)").eq("case_id", case_id).order("confidence", desc=True).execute().data or []
        result = []
        for row in rows:
            result.append({
                "id": str(row["id"]),
                "wallet_address": row.get("wallets", {}).get("address"),
                "entity_name": row.get("entities", {}).get("name"),
                "entity_type": row.get("entities", {}).get("type"),
                "match_type": row["match_type"],
                "confidence": float(row["confidence"]),
                "evidence": row["evidence"],
                "created_at": row["created_at"],
            })
        return ok({"attributions": result})
    except Exception as exc:
        return db_error(exc)


@app.get("/api/cases/<case_id>/risk")
def get_risk(case_id: str):
    if not valid_uuid(case_id) or not case_exists(case_id):
        return fail("CASE_NOT_FOUND", "Case does not exist.", 404)
    try:
        assessment_rows = supabase.table("risk_assessments").select("*").eq("case_id", case_id).order("created_at", desc=True).limit(1).execute().data or []
        if not assessment_rows:
            assessment = build_risk(case_id)
        else:
            assessment = assessment_rows[0]
        indicators = supabase.table("risk_indicators").select("id, code, description, severity, evidence").eq("risk_assessment_id", assessment["id"]).execute().data or []
        return ok({"id": str(assessment["id"]), "score": assessment["score"], "level": assessment["level"], "indicators": indicators, "created_at": assessment["created_at"]})
    except Exception as exc:
        return db_error(exc)


@app.get("/api/cases/<case_id>/report")
def get_report(case_id: str):
    if not valid_uuid(case_id) or not case_exists(case_id):
        return fail("CASE_NOT_FOUND", "Case does not exist.", 404)
    try:
        case = fetch_one("cases", "id", case_id)
        wallet_links = supabase.table("case_wallets").select("wallet_id, type").eq("case_id", case_id).execute().data or []
        wallet = fetch_one("wallets", "id", wallet_links[0]["wallet_id"]) if wallet_links else None
        tx_response = get_transactions(case_id)
        tx_data = tx_response[0].get_json()["data"] if isinstance(tx_response, tuple) else tx_response.get_json()["data"]
        graph_response = get_graph(case_id)
        graph_data = graph_response[0].get_json()["data"] if isinstance(graph_response, tuple) else graph_response.get_json()["data"]
        attr = get_attribution(case_id)
        attr_data = attr[0].get_json()["data"] if isinstance(attr, tuple) else attr.get_json()["data"]
        risk = get_risk(case_id)
        risk_data = risk[0].get_json()["data"] if isinstance(risk, tuple) else risk.get_json()["data"]
        return ok({"case": serialize_row(case), "wallet": serialize_row(wallet) if wallet else None, "transactions": tx_data["transactions"], "graph": graph_data, "attributions": attr_data["attributions"], "risk": risk_data})
    except Exception as exc:
        return db_error(exc)


@app.errorhandler(404)
def not_found(_):
    return fail("INTERNAL_ERROR", "Endpoint not found.", 404)


@app.errorhandler(500)
def internal(_):
    return fail("INTERNAL_ERROR", "Unexpected server error.", 500)


if __name__ == "__main__":
    app.run(host="0.0.0.0", port=int(os.getenv("PORT", "5000")), debug=True)
