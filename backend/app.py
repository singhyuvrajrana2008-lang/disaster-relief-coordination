"""
ReliefRoute Backend - Flask Application
Member 3: Backend + Offline System
"""

import os
from uuid import UUID

from dotenv import load_dotenv
from flask import Flask, jsonify, request
from supabase import create_client

load_dotenv()

app = Flask(__name__)

SUPABASE_URL = os.getenv("SUPABASE_URL")
SUPABASE_KEY = os.getenv("SUPABASE_KEY")
ENABLE_CLIENT_REPORT_ID = os.getenv("ENABLE_CLIENT_REPORT_ID", "false").lower() == "true"

supabase = None
if SUPABASE_URL and SUPABASE_KEY:
    supabase = create_client(SUPABASE_URL, SUPABASE_KEY)


REPORT_ALLOWED_FIELDS = {
    "shelter_id",
    "resource_id",
    "quantity_needed",
    "description",
    "latitude",
    "longitude",
    "reported_by",
    "client_report_id",
}


def success_response(data=None, status_code=200):
    response = jsonify({
        "success": True,
        "data": data,
        "error": None,
    })
    response.status_code = status_code
    return response


def error_response(code, message, status_code=400):
    response = jsonify({
        "success": False,
        "data": None,
        "error": {
            "code": code,
            "message": message,
        },
    })
    response.status_code = status_code
    return response


def is_uuid(value):
    try:
        UUID(str(value))
        return True
    except (ValueError, TypeError, AttributeError):
        return False


def validate_report(payload):
    if not isinstance(payload, dict):
        return "INVALID_JSON", "Request body must be a JSON object."

    unknown_fields = sorted(set(payload) - REPORT_ALLOWED_FIELDS)
    if unknown_fields:
        return "UNKNOWN_FIELD", f"Unknown field(s): {', '.join(unknown_fields)}."

    resource_id = payload.get("resource_id")
    if not resource_id:
        return "MISSING_RESOURCE", "resource_id is required."
    if not is_uuid(resource_id):
        return "INVALID_RESOURCE_ID", "resource_id must be a valid UUID."

    quantity = payload.get("quantity_needed")
    if quantity is None:
        return "MISSING_QUANTITY", "quantity_needed is required."
    if isinstance(quantity, bool) or not isinstance(quantity, int) or quantity <= 0:
        return "INVALID_QUANTITY", "quantity_needed must be a positive integer."

    for field in ("shelter_id", "reported_by"):
        if payload.get(field) is not None and not is_uuid(payload[field]):
            return f"INVALID_{field.upper()}", f"{field} must be a valid UUID."

    latitude = payload.get("latitude")
    longitude = payload.get("longitude")
    if (latitude is None) != (longitude is None):
        return "INCOMPLETE_LOCATION", "latitude and longitude must be provided together."
    if latitude is not None:
        if isinstance(latitude, bool) or not isinstance(latitude, (int, float)) or not -90 <= latitude <= 90:
            return "INVALID_LATITUDE", "latitude must be a number between -90 and 90."
        if isinstance(longitude, bool) or not isinstance(longitude, (int, float)) or not -180 <= longitude <= 180:
            return "INVALID_LONGITUDE", "longitude must be a number between -180 and 180."

    description = payload.get("description")
    if description is not None and (not isinstance(description, str) or len(description) > 2000):
        return "INVALID_DESCRIPTION", "description must be text with at most 2000 characters."

    client_report_id = payload.get("client_report_id")
    if client_report_id is not None:
        if not isinstance(client_report_id, str) or not client_report_id.strip() or len(client_report_id) > 100:
            return "INVALID_CLIENT_REPORT_ID", "client_report_id must be non-empty text up to 100 characters."
        if not ENABLE_CLIENT_REPORT_ID:
            return "SCHEMA_MIGRATION_REQUIRED", "client_report_id is not enabled yet. Member 1 must add the database column before offline duplicate protection can be used."

    return None, None


@app.route("/api/health", methods=["GET"])
def health_check():
    return success_response({"status": "ReliefRoute backend is running"})


@app.route("/api/reports", methods=["POST"])
def create_report():
    if supabase is None:
        return error_response(
            "BACKEND_CONFIG_ERROR",
            "Supabase is not configured. Check SUPABASE_URL and SUPABASE_KEY in .env.",
            500,
        )

    payload = request.get_json(silent=True)
    error_code, error_message = validate_report(payload)
    if error_code:
        status = 503 if error_code == "SCHEMA_MIGRATION_REQUIRED" else 400
        return error_response(error_code, error_message, status)

    client_report_id = payload.get("client_report_id")

    try:
        # Check referenced records first so the API returns clear client errors.
        resource_result = (
            supabase.table("resources")
            .select("id")
            .eq("id", payload["resource_id"])
            .limit(1)
            .execute()
        )
        if not resource_result.data:
            return error_response("RESOURCE_NOT_FOUND", "The requested resource does not exist.", 404)

        shelter_id = payload.get("shelter_id")
        if shelter_id:
            shelter_result = (
                supabase.table("shelters")
                .select("id")
                .eq("id", shelter_id)
                .limit(1)
                .execute()
            )
            if not shelter_result.data:
                return error_response("SHELTER_NOT_FOUND", "The requested shelter does not exist.", 404)

        # Once Member 1 adds reports.client_report_id, this makes offline retries idempotent.
        if client_report_id:
            duplicate_result = (
                supabase.table("reports")
                .select("*")
                .eq("client_report_id", client_report_id)
                .limit(1)
                .execute()
            )
            if duplicate_result.data:
                existing = duplicate_result.data[0]
                return success_response({"report": existing, "duplicate": True})

        insert_data = {
            key: value
            for key, value in payload.items()
            if key != "client_report_id"
        }
        if client_report_id:
            insert_data["client_report_id"] = client_report_id

        result = supabase.table("reports").insert(insert_data).execute()
        created = result.data[0] if result.data else None

        return success_response({"report": created, "duplicate": False}, 201)

    except Exception as exc:
        # Do not expose raw Supabase/service-role details to clients.
        app.logger.exception("Failed to create report: %s", exc)
        return error_response(
            "DATABASE_ERROR",
            "The report could not be saved. Please try again.",
            500,
        )


if __name__ == "__main__":
    app.run(debug=True, port=5000)
