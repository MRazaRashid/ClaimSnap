# ClaimSnap API: example requests

Each operation is its own Logic App, so each has its own trigger URL. Get them with:

```bash
RG=rg-claimsnap-uks ./scripts/write-config.sh && cat frontend/js/config.js
```

or in the portal: *Logic App → Overview → Workflow URL*. In the examples below, `$IUPS`, `$RAI` and so on are those URLs with `{claimId}` / `{evidenceId}` replaced. The same requests work in Postman.

Seeded data: users `1` Aoife Byrne (policyholder of CS-24817 and CS-24819), `2` Daniel Okafor (policyholder of CS-24818), `3` Sarah Whitmore (adjuster).

## IUPS: create

```bash
ID=$(uuidgen | tr A-Z a-z)
DATA=$(base64 -w0 roof.jpg)
curl -s -X POST "$IUPS" -H "Content-Type: application/json" -d @- <<EOF
{ "evidenceId": "$ID", "userId": 1, "fileName": "roof.jpg",
  "caption": "Tuiles arrachées sur le toit", "area": "Roof", "damageTags": ["roof"],
  "data": "$DATA" }
EOF
```

`201 Created`

```json
{ "evidenceId": "5f0c…", "claimId": "CS-24817", "fileLocator": "claims/CS-24817/5f0c….jpg",
  "sha256": "9b1e…", "status": "Active" }
```

| Try | Result |
|---|---|
| Same request again | `409` This evidence item is already stored |
| `userId: 2` on CS-24817 | `403` You cannot add evidence to this claim |
| Claim `CS-99999` | `404` Claim not found |
| A GIF or PDF renamed to .jpg | `415` Only JPEG and PNG photos are accepted |
| File over 10 MB | `413` Photos must be 10 MB or smaller |
| Missing `evidenceId` | `400` schema validation error |

## RAI: retrieve all for a claim

```bash
curl -s "$RAI"        # .../claims/CS-24817/evidence
```

`200 OK`

```json
{
  "claim": { "claimRef": "CS-24817", "policyNumber": "HH-0093321", "claimStatus": "InReview",
             "eventName": "Storm Darragh", "policyholder": "Aoife Byrne", "adjuster": "Sarah Whitmore" },
  "items": [
    { "evidenceId": "5f0c…", "fileName": "roof.jpg", "status": "Active", "sha256": "9b1e…",
      "caption": "Tuiles arrachées sur le toit", "uploadedByName": "Aoife Byrne",
      "readUrl": "https://stclaimsnap….blob.core.windows.net/evidence-originals/claims/CS-24817/5f0c….jpg?sv=…&se=…&sp=r&sig=…",
      "metadata": { "area": "Roof", "damageTags": ["roof"], "captionLang": "fr",
                    "captionEn": "Tiles torn off the roof",
                    "exif": { "capturedUtc": "2026-11-09T18:42:10.000Z", "gps": { "lat": 54.6, "lon": -5.93 }, "device": "Apple iPhone 15" } } }
  ]
}
```

## RIPS: retrieve one

```bash
curl -s "$RIPS"       # .../evidence/5f0c…
```

`200 OK`: the same item, plus `audit`:

```json
"audit": [ { "action": "Create", "detail": "roof.jpg", "atUtc": "…", "byUser": "Aoife Byrne" } ]
```

## UIPS: update caption and tags

```bash
curl -s -X PUT "$UIPS" -H "Content-Type: application/json" \
  -d '{ "userId": 3, "caption": "Roof tiles missing, north side", "damageTags": ["roof", "tiles"] }'
```

`200 OK` with the updated item and metadata. `409` if the item is voided, `403` for another policyholder.

## DIPS: void (soft delete)

```bash
curl -s -i -X DELETE "$DIPS&userId=3&reason=Duplicate%20photo"
```

`204 No Content`. A second call returns `409`; `userId=1` (not an adjuster) returns `403`.
The item stays visible to adjusters as *Voided* with the reason in its audit trail; the blob is not deleted.
