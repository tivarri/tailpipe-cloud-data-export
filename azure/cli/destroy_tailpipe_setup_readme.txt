# Tailpipe Cleanup — `destroy_tailpipe_setup.sh`

This script **undoes** the Tailpipe Azure setup created by the deploy script. It is **idempotent** and safe to run multiple times.

## What it removes

- **Cost Management exports**
  - **Per-subscription** exports (CSP and fallback MCA/EA):
    - `TailpipeDataExport-<last6>` (current naming)
    - `TailpipeDataExport` (legacy naming)
  - **Billing-scope** export (MCA/EA): `TailpipeAllSubs` at the Billing Profile/Account scope (if visible)
- **RBAC assignments**
  - **Monitoring Reader**
    - At **Root Management Group** scope (preferred)
    - Fallback: at **each subscription** scope
  - **Storage Blob Data Reader** on the **host storage account** used for exports
- **Resource group** that hosts storage: defaults to `tailpipe-dataexport` (deletes the storage account + container)

**Optional:** delete the **TailpipeConnector** service principal from the customer tenant (`--delete-sp` or `DELETE_SP=1`).

---

## Requirements

- **Azure CLI** authenticated to the **target tenant**  
  ```bash
  az account clear
  az login --tenant <tenantId>