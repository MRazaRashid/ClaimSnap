#!/usr/bin/env bash
# Deletes every ClaimSnap resource so nothing keeps billing after the assessment.
set -euo pipefail
: "${RG:?set RG}"
read -r -p "Delete resource group $RG and everything in it? Type the name to confirm: " answer
[ "$answer" = "$RG" ] || { echo "Cancelled."; exit 1; }
az group delete -n "$RG" --yes --no-wait
echo "Deletion started. Cosmos DB and SQL take a few minutes to disappear."
