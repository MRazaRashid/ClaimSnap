# ClaimSnap

Storm-damage photo evidence for UK home-insurance claims. Policyholders upload damage photos from their phones; loss adjusters review, caption, verify and void them. Built on Microsoft Azure for COM682 Cloud Native Development (Coursework 2), implementing the CW1 design.

**Muhammad Raza · B00978418**

## Architecture

```
Browser (policyholder / adjuster)
   │  HTML, CSS, JS from the Storage static website ($web)
   │
   │  JSON over HTTPS
   ▼
Logic Apps (Consumption) ── REST API, one workflow per operation
   │ IUPS  POST   /claims/{claimId}/evidence ──► Azure Function "inspect" (type check, SHA-256, EXIF)
   │                                         ──► Azure AI Translator (caption → English)
   │ RAI   GET    /claims/{claimId}/evidence
   │ RIPS  GET    /evidence/{evidenceId}
   │ UIPS  PUT    /evidence/{evidenceId}     ──► Azure AI Translator
   │ DIPS  DELETE /evidence/{evidenceId}
   │
   ├──► Blob Storage    evidence-originals (private, ZRS)   the photo bytes
   ├──► Azure SQL       claims, users, evidence index, audit (via stored procedures)
   └──► Cosmos DB       per-photo metadata: EXIF, tags, translation (pk /claimId)

Photos are read straight from Blob through 15-minute read-only SAS links (valet key).
Logic App run history → Log Analytics; failed-run alerts and a monthly budget → email.
Function → Application Insights.
```

### Azure resources

| Resource | Name (suffix is generated) | Purpose |
|---|---|---|
| Storage account (LRS) | `stclaimsnapweb…` | Static website `$web`, function host storage |
| Storage account (ZRS) | `stclaimsnap…` | Private `evidence-originals` container, soft delete 30 days, lifecycle Hot → Cool (30 d) → Cold (90 d), CORS for the site |
| Azure SQL (serverless) | `sql-claimsnap-…/claimsnapdb` | 5 tables in 3NF, view, 6 stored procedures |
| Cosmos DB (NoSQL) | `cosmos-claimsnap-…` → `evidence/metadata` | Photo metadata, partition key `/claimId`, autoscale up to 1,000 RU/s |
| Logic Apps ×5 | `la-claimsnap-iups/rai/rips/uips/dips` | REST endpoints (full CRUD) |
| API connections | `azureblob`, `sql`, `documentdb` | Used by the Logic Apps |
| Function App (Consumption) | `func-claimsnap-…` | `inspect` HTTP function (Node.js 22) |
| Azure AI Translator | `tr-claimsnap-…` | Caption translation |
| Log Analytics + App Insights | `log-claimsnap`, `appi-claimsnap` | Logs, metrics, function telemetry |
| Action group, metric alerts, budget | `ag-claimsnap`, `alert-*-failed-runs`, `budget-claimsnap` | Email on failed runs and on spend |

## REST API

| Op | Method and URI | Body / query | Responses |
|---|---|---|---|
| IUPS (create) | `POST /claims/{claimId}/evidence` | `{ evidenceId, userId, fileName, caption, area, damageTags, data (base64) }` | 201, 400, 403, 404, 409, 413, 415, 500 |
| RAI (retrieve all) | `GET /claims/{claimId}/evidence` | | 200 `{ claim, items[] }`, 404 |
| RIPS (retrieve one) | `GET /evidence/{evidenceId}` | | 200 item + `readUrl` + `metadata` + `audit`, 404 |
| UIPS (update) | `PUT /evidence/{evidenceId}` | `{ userId, caption, damageTags }` | 200, 400, 403, 404, 409 |
| DIPS (delete) | `DELETE /evidence/{evidenceId}?userId=3&reason=…` | | 204, 403, 404, 409 |

Example calls are in [docs/api.md](docs/api.md).

How the rules work:

- **The original photo is never changed.** Update edits the caption and tags only. Delete is a soft delete: the item is marked `Voided`, an audit row is written and the blob stays (soft delete and lifecycle tiering then manage retention).
- **Uploads are safe to retry.** The browser creates `evidenceId` before sending, so a retry after a dropped connection returns 409 rather than storing a duplicate. The browser retries network errors, 429 and 5xx with backoff.
- **No half-written uploads.** IUPS registers the item in SQL, then writes the blob and the Cosmos document inside a scope. If either write fails, a compensation scope deletes the blob, removes the SQL row and returns 500.
- **The server decides the file type.** The function reads the first bytes (JPEG/PNG signature) instead of trusting the file name or the header the client sent, and rejects files over 10 MB.
- **Access rules live in the database.** Only the claim's policyholder or an adjuster can add or edit evidence, and only an adjuster can void it. The Logic Apps connect as `claimsnap_api`, which can **only execute the stored procedures**, so the tables and audit log cannot be changed directly through the API.

## Advanced features

1. **Azure Functions (Lab 7).** The `inspect` HTTP-triggered function (Node.js) is called by IUPS before anything is stored. It validates the file type and size, computes the SHA-256 hash (stored in SQL for tamper evidence) and extracts EXIF capture time, GPS and device (stored in Cosmos DB). Logic Apps cannot do these steps on their own. The adjuster console's *Verify integrity* button downloads the original through its SAS link and re-checks the hash in the browser.
2. **Azure AI Translator (Lab 12).** IUPS and UIPS send the caption to Translator. The detected language and the English text are stored in Cosmos DB, and the adjuster sees "Translated from PL: …" next to the original caption.
3. **Azure Monitor and Application Insights.** All five Logic Apps send run history and metrics to Log Analytics; a metric alert per Logic App emails the owner when there are more than 2 failed runs in 15 minutes. The function reports to Application Insights.
4. **CI/CD with Azure DevOps Pipelines (Lab 10).** On every push to `main`: install, run the unit tests, check the front-end scripts, package the function. Then it deploys the function and uploads the static site, generating `config.js` from the live Logic App URLs.
5. **Cost control and data lifecycle.** A monthly budget with alerts at 50%, 80% and a forecast of 100%, blob lifecycle tiering, a serverless SQL database that pauses when idle, and capped Cosmos DB autoscale.

## Changes from the CW1 design

| CW1 design | Implemented | Why |
|---|---|---|
| Endpoints `getEvidence`, `updateMeta`, `voidEvidence` | `RIPS`, `UIPS`, `DIPS` | Same operations, renamed to match the IUPS/RAI naming used in the labs |
| Photo validated and hashed "on upload" | Done in an Azure Function called by the Logic App | Logic Apps have no SHA-256 or EXIF actions |
| Lifecycle Hot → Cool → Archive | Hot → Cool → Cold | Archive tier is not supported on ZRS accounts, and ZRS was chosen for resilience |
| Managed identity for connectors | Keys held in the API connections (set by Bicep, never in the repo) plus a SQL login limited to EXECUTE | The managed SQL connector with stored procedures was simpler and more reliable with SQL authentication. Least privilege is enforced in the database instead |
| Azure CDN | Not added | The site is a few small static files; CDN/Front Door would add cost with little benefit at this scale |
| Translator: "optional AI damage tags" | Translation only | Tags are entered by people; automatic tags were left out so that software never influences a claim decision (CW1 ethics point) |
| Entra ID sign-in | Simulated sign-in with the seeded users; role checks in SQL | Out of scope for the module labs; listed as a limitation in CW1 |

## Project structure

```
database/        01-schema.sql (tables, view, seed data, API login), 02-procedures.sql
functions/       Azure Function app: src/image.js (logic), src/functions/inspect.js (HTTP trigger), tests
frontend/        index.html (policyholder upload), adjuster.html (console), css/, js/
infra/           main.bicep (core resources), api.bicep (connections, Logic Apps, monitoring, budget)
infra/workflows/ Logic App definitions (same JSON as the designer's code view)
scripts/         deploy.sh, write-config.sh, teardown.sh
azure-pipelines.yml
```

## Deploying

### Prerequisites

- An Azure subscription where you are Owner or Contributor. This is billed: see *Costs* below.
- [Azure CLI](https://learn.microsoft.com/cli/azure/install-azure-cli) (includes Bicep), logged in with `az login`
- Node.js 22 and [Azure Functions Core Tools v4](https://learn.microsoft.com/azure/azure-functions/functions-run-local)
- Optional: [sqlcmd](https://learn.microsoft.com/sql/tools/sqlcmd/go-sqlcmd-utilities) (otherwise use the portal Query editor)
- On Windows, run the scripts from Git Bash

### 1. Deploy

```bash
export RG=rg-claimsnap-uks LOCATION=uksouth ALERT_EMAIL=you@example.com
export SQL_ADMIN_PASSWORD='<strong password>' SQL_API_PASSWORD='<another strong password>'
./scripts/deploy.sh all
```

Avoid `/`, `&` and `'` in the passwords, because the script substitutes them into SQL.

Or run it stage by stage: `infra`, `database`, `function`, `api`, `site`. The order matters: the Logic Apps need the SQL login and the function key to exist.

**Without sqlcmd:** after the `infra` stage, open *SQL database → Query editor* in the portal, sign in as `claimsnapadmin`, run `01-schema.sql` (replace `__API_PASSWORD__` with your `SQL_API_PASSWORD`), then `02-procedures.sql`. Continue with `./scripts/deploy.sh function`, `api` and `site`.

**Free offers.** The template uses the Azure SQL free offer and the free (F0) Translator tier. Each is allowed once per subscription. If the deployment fails because one is already in use, rerun with `SQL_FREE_OFFER=false` and/or `TRANSLATOR_SKU=S1`. If no other Cosmos DB account in the subscription uses the free tier, `COSMOS_FREE_TIER=true` removes the Cosmos cost.

The site URL is printed at the end (`https://stclaimsnapweb….z33.web.core.windows.net`).

### 2. CI/CD pipeline (Azure DevOps + GitHub)

1. Push this folder to a GitHub repository.
2. In Azure DevOps, create a project. Under **Project settings → Service connections**, add an *Azure Resource Manager* connection to the subscription and name it `claimsnap-azure`. Scope it to the resource group.
3. **Pipelines → New pipeline → GitHub →** select the repo. It picks up `azure-pipelines.yml`.
4. Run it. The first run asks you to approve access to the service connection and creates the `claimsnap-production` environment.

Any push to `main` then tests, builds and redeploys the function and the site.

### Running locally

```bash
./scripts/write-config.sh            # needs RG set and az login; writes frontend/js/config.js
npx serve frontend -l 5500           # or VS Code Live Server on port 5500
cd functions && npm install && npm test
```

## Testing

- `functions/`: `npm test` runs unit tests for type detection, size limits and hashing.
- API: the requests in [docs/api.md](docs/api.md) cover every status code (including 403/409 role and state rules).
- End to end: upload on `index.html` as Aoife Byrne to claim `CS-24817`, then open `adjuster.html` as Sarah Whitmore to edit, translate, verify and void.

Tips for testing:

- The serverless SQL database pauses after 60 minutes idle, and the first request after that can fail while it resumes (about a minute). Open the site once beforehand.
- Write a caption in another language (for example *"Dach uszkodzony przez burzę"*) to see the translation.
- A photo taken on a phone with location turned on shows its capture time, GPS and device in the console.

## Costs

Rough monthly cost at demo usage in UK South (check the [pricing calculator](https://azure.microsoft.com/pricing/calculator/) for current prices):

| Resource | Cost |
|---|---|
| Logic Apps, Function (Consumption), Blob, static site | Pennies: billed per run, execution and GB |
| Azure SQL serverless | Free with the free offer; otherwise only while active (pauses after 1 h) |
| Cosmos DB autoscale (max 1,000 RU/s) | About £7–9 a month at the 100 RU/s minimum, or free with the free tier |
| Translator F0 / S1 | Free up to 2M characters / about £8 per million characters |
| Log Analytics, App Insights | Small: pay per GB ingested, first 5 GB/month free |

The budget (default 20 in the subscription currency, `MONTHLY_BUDGET` to change) emails you at 50% and 80%, and when the forecast reaches 100%. When the project is finished:

```bash
RG=rg-claimsnap-uks ./scripts/teardown.sh
```

## Known limitations

- Sign-in is simulated. Anyone with the page can choose a user, and the Logic App URLs carry their own signature. Next step: Entra ID sign-in, with API Management validating tokens in front of the Logic Apps.
- Photos travel through the Logic App as base64 (about 33% larger). Fine at 10 MB, but direct-to-Blob upload with a write-only SAS would remove the bytes from the API path.
- Translator or the function failing stops an upload. Both are retried by the Logic App's default retry policy first.
- SQL scales vertically. With ~1 KB rows it is not the bottleneck at the CW1 surge figures, but it is the one tier that does not scale out.

## References

- Microsoft (2026) *Azure Logic Apps documentation*. https://learn.microsoft.com/azure/logic-apps/
- Microsoft (2026) *Compensating Transaction pattern*. https://learn.microsoft.com/azure/architecture/patterns/compensating-transaction
- Microsoft (2026) *Valet Key pattern*. https://learn.microsoft.com/azure/architecture/patterns/valet-key
- Microsoft (2026) *Access tiers for blob data*. https://learn.microsoft.com/azure/storage/blobs/access-tiers-overview
- Microsoft (2026) *Azure SQL Database free offer*. https://learn.microsoft.com/azure/azure-sql/database/free-offer
- Microsoft (2026) *Translator v3.0 reference*. https://learn.microsoft.com/azure/ai-services/translator/reference/v3-0-reference
- Ulster University (2026) *COM682 Cloud Native Development: Labs 1–12*. Blackboard.
