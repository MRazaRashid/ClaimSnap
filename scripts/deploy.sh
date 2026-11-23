#!/usr/bin/env bash
# ClaimSnap deployment with the Azure CLI.
#
#   export RG=rg-claimsnap-uks LOCATION=uksouth ALERT_EMAIL=you@example.com
#   export SQL_ADMIN_PASSWORD='...' SQL_API_PASSWORD='...'
#   optional: SQL_FREE_OFFER=false COSMOS_FREE_TIER=true TRANSLATOR_SKU=S1 MONTHLY_BUDGET=30
#   ./scripts/deploy.sh all          # or one stage: infra | database | function | api | site
#
# Stages run in order because each needs the previous one:
#   infra -> database (creates the API login) -> function (key must exist) -> api -> site
set -euo pipefail
cd "$(dirname "$0")/.."

: "${RG:?set RG}" "${LOCATION:=uksouth}"
STAGE="${1:-all}"

output() { az deployment group show -g "$RG" -n claimsnap-main --query "properties.outputs.$1.value" -o tsv; }

infra() {
  az group show -n "$RG" -o none
  az deployment group create -g "$RG" -n claimsnap-main -f infra/main.bicep \
    -p location="$LOCATION" clientIp="$(curl -s https://api.ipify.org)" \
       sqlFreeOffer="${SQL_FREE_OFFER:-true}" cosmosFreeTier="${COSMOS_FREE_TIER:-false}" \
       translatorSku="${TRANSLATOR_SKU:-F0}" -o none
  # Static website hosting is a data-plane setting, so it is switched on here rather than in Bicep
  az storage blob service-properties update --account-name "$(output webStorageName)" --auth-mode key \
    --static-website --index-document index.html --404-document index.html -o none
  echo "Infrastructure ready. Website: $(output websiteUrl)"
}

database() {
  : "${SQL_ADMIN_PASSWORD:?set SQL_ADMIN_PASSWORD}" "${SQL_API_PASSWORD:?set SQL_API_PASSWORD}"
  if ! command -v sqlcmd >/dev/null; then
    echo "sqlcmd not found. Run database/01-schema.sql then 02-procedures.sql in the portal Query editor,"
    echo "replacing __API_PASSWORD__ with your SQL_API_PASSWORD."
    return
  fi
  local server db
  server="$(output sqlServerFqdn)"; db="$(output sqlDatabaseName)"
  sed "s/__API_PASSWORD__/${SQL_API_PASSWORD//\'/\'\'}/" database/01-schema.sql |
    sqlcmd -S "$server" -d "$db" -U claimsnapadmin -P "$SQL_ADMIN_PASSWORD" -b
  sqlcmd -S "$server" -d "$db" -U claimsnapadmin -P "$SQL_ADMIN_PASSWORD" -b -i database/02-procedures.sql
  echo "Database schema, seed data and procedures created."
}

function_app() {
  (cd functions && npm ci --omit=dev && func azure functionapp publish "$(output functionAppName)" --javascript)
}


api() {
  : "${RG:?set RG}"
  : "${LOCATION:?set LOCATION}"
  : "${ALERT_EMAIL:?set ALERT_EMAIL}"

  az deployment group create \
    --resource-group "$RG" \
    --name claimsnap-api \
    --template-file infra/api.bicep \
    --parameters \
      location="$LOCATION" \
      evidenceStorageName="stclaimsnapjlviif" \
      cosmosAccountName="cosmos-claimsnap-jlviif" \
      sqlServerName="sql-claimsnap-jlviif" \
      sqlDatabaseName="claimsnapdb" \
      functionAppName="func-claimsnap-jlviif" \
      translatorName="tr-claimsnap-jlviif" \
      alertEmail="$ALERT_EMAIL" \
      monthlyBudget="${MONTHLY_BUDGET:-20}"

  echo "ClaimSnap Logic Apps API deployed."
}


site() {
  : "${RG:?set RG}"

  local storage="stclaimsnapwebjlviif"

  # Do not generate or publish signed Logic App URLs.
  echo "Deploying ClaimSnap static website..."

  az storage blob service-properties update \
    --account-name "$storage" \
    --auth-mode key \
    --static-website \
    --index-document index.html \
    --404-document index.html \
    --output none

  az storage blob upload-batch \
    --account-name "$storage" \
    --auth-mode key \
    --destination '$web' \
    --source frontend \
    --overwrite \
    --output none

  az storage account show \
    --resource-group "$RG" \
    --name "$storage" \
    --query "primaryEndpoints.web" \
    --output tsv
}


case "$STAGE" in
  infra) infra ;;
  database) database ;;
  function) function_app ;;
  api) api ;;
  site) site ;;
  all) infra; database; function_app; api; site ;;
  *) echo "Unknown stage: $STAGE"; exit 1 ;;
esac
