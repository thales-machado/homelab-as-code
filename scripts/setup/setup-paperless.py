#!/usr/bin/env python3
"""
Homelab - Paperless-ngx Setup
==============================
Provisions document types, storage paths and workflows that automatically
classify GC's (Instituto Neuroeducacional) financial receipts via the
Paperless REST API. Idempotent - rerunning does not create duplicates.

Usage:
  pip install requests
  PAPERLESS_TOKEN=<token> python3 setup-paperless.py

Token: generated via POST /api/token/ with the admin user/password, or taken
from Settings > API Tokens in Paperless itself.
"""

import os
import sys

import requests

PAPERLESS_URL = os.getenv("PAPERLESS_URL", "http://192.168.10.214:8000")
TOKEN = os.getenv("PAPERLESS_TOKEN", "")

if not TOKEN:
    sys.exit("Set PAPERLESS_TOKEN in the environment before running.")

HEADERS = {"Authorization": f"Token {TOKEN}", "Content-Type": "application/json"}

# =============================================================================
# DOCUMENT TYPES
# =============================================================================
DOCUMENT_TYPES = [
    "Comprovante Pagamento",
    "Comprovante Recebimento",
    "Extrato Bancario",
]

# =============================================================================
# STORAGE PATHS
# name -> path template (Paperless Jinja2 placeholders)
# =============================================================================
STORAGE_PATHS = {
    "Comprovantes - Pagamentos": (
        "Financeiro/Comprovantes/Pagamentos/{{ created_year }}/{{ created_month }}/{{ title }}"
    ),
    "Comprovantes - Recebimentos": (
        "Financeiro/Comprovantes/Recebimentos/{{ created_year }}/{{ created_month }}/{{ title }}"
    ),
    "Extrato": (
        "Financeiro/Extrato/{{ created_year }}/{{ created_month }}/{{ title }}"
    ),
}

# =============================================================================
# WORKFLOWS
# name -> (regex, document_type, storage_path)
# =============================================================================
WORKFLOWS = [
    (
        "GC - Classificar Comprovante Pagamento",
        r"DADOS DE ORIGEM[\s\S]{0,80}Instituto Neuroeducacional",
        "Comprovante Pagamento",
        "Comprovantes - Pagamentos",
    ),
    (
        "GC - Classificar Comprovante Recebimento",
        r"(Recebedor|Para)[\s\S]{0,60}Instituto Neuroeducacional|VIA LOJISTA",
        "Comprovante Recebimento",
        "Comprovantes - Recebimentos",
    ),
    (
        "GC - Classificar Extrato Bancario",
        r"Extrato de conta corrente",
        "Extrato Bancario",
        "Extrato",
    ),
]

TRIGGER_TYPE_DOCUMENT_ADDED = 2  # Consumption Started runs before OCR, so content matching does not work there
MATCHING_ALGORITHM_REGEX = 4
ACTION_TYPE_ASSIGNMENT = 1


def get_or_create(endpoint, name, extra_fields=None):
    resp = requests.get(f"{PAPERLESS_URL}/api/{endpoint}/", headers=HEADERS, params={"name__iexact": name})
    resp.raise_for_status()
    results = resp.json()["results"]
    if results:
        existing = results[0]
        drifted = extra_fields and any(existing.get(k) != v for k, v in extra_fields.items())
        if drifted:
            resp = requests.patch(f"{PAPERLESS_URL}/api/{endpoint}/{existing['id']}/", headers=HEADERS, json=extra_fields)
            resp.raise_for_status()
            print(f"  updated: {name} (id={existing['id']})")
        else:
            print(f"  already exists: {name} (id={existing['id']})")
        return existing["id"]

    payload = {"name": name}
    if extra_fields:
        payload.update(extra_fields)
    resp = requests.post(f"{PAPERLESS_URL}/api/{endpoint}/", headers=HEADERS, json=payload)
    resp.raise_for_status()
    created = resp.json()
    print(f"  created: {name} (id={created['id']})")
    return created["id"]


def get_workflow_by_name(name):
    # /api/workflows/ does not support filtering by name via query param (it
    # is silently ignored and returns everything), so filter client-side
    resp = requests.get(f"{PAPERLESS_URL}/api/workflows/", headers=HEADERS)
    resp.raise_for_status()
    for wf in resp.json()["results"]:
        if wf["name"].lower() == name.lower():
            return wf
    return None


def upsert_workflow(name, regex, document_type_id, storage_path_id, order):
    payload = {
        "name": name,
        "order": order,
        "enabled": True,
        "triggers": [
            {
                "type": TRIGGER_TYPE_DOCUMENT_ADDED,
                "matching_algorithm": MATCHING_ALGORITHM_REGEX,
                "match": regex,
                "is_insensitive": True,
            }
        ],
        "actions": [
            {
                "type": ACTION_TYPE_ASSIGNMENT,
                "assign_document_type": document_type_id,
                "assign_storage_path": storage_path_id,
            }
        ],
    }

    existing = get_workflow_by_name(name)
    if existing:
        resp = requests.put(f"{PAPERLESS_URL}/api/workflows/{existing['id']}/", headers=HEADERS, json=payload)
        resp.raise_for_status()
        print(f"  updated: {name} (id={existing['id']})")
    else:
        resp = requests.post(f"{PAPERLESS_URL}/api/workflows/", headers=HEADERS, json=payload)
        resp.raise_for_status()
        print(f"  created: {name} (id={resp.json()['id']})")


def main():
    print("Document types:")
    doc_type_ids = {name: get_or_create("document_types", name) for name in DOCUMENT_TYPES}

    print("\nStorage paths:")
    storage_path_ids = {
        name: get_or_create("storage_paths", name, extra_fields={"path": path})
        for name, path in STORAGE_PATHS.items()
    }

    print("\nWorkflows:")
    for order, (name, regex, doc_type, storage_path) in enumerate(WORKFLOWS, start=1):
        upsert_workflow(
            name=name,
            regex=regex,
            document_type_id=doc_type_ids[doc_type],
            storage_path_id=storage_path_ids[storage_path],
            order=order,
        )

    print("\nOK")


if __name__ == "__main__":
    main()
