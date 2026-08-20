# Disaster Relief MVP — API Contract

## 1. Report a Relief Need

### POST /reports

Used when a shelter/reporter submits a request for supplies.

### Request

```json
{
  "shelter_id": "uuid",
  "resource_id": "uuid",
  "quantity_needed": 100,
  "description": "Need drinking water urgently",
  "latitude": 30.123,
  "longitude": 76.456
}