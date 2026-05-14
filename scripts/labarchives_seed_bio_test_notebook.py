#!/usr/bin/env python3
"""Create and populate a dedicated LabArchives notebook for ELNLA testing.

The script reads credentials and UID from local_credentials/, creates a new
notebook, adds folders/pages, writes text/rich-text content, uploads bio-lab
fixture files, and saves all returned IDs locally. It deliberately prints only
high-level progress; exact IDs stay in ignored local files.
"""

from __future__ import annotations

import base64
import csv
import hashlib
import hmac
import json
import os
from pathlib import Path
import textwrap
import time
from typing import Dict, Iterable, Tuple
from urllib import parse, request
import xml.etree.ElementTree as ET


ROOT = Path(__file__).resolve().parents[1]
LOCAL = ROOT / "local_credentials"
BASE_URL = "https://api.labarchives-gov.com"


def load_env(path: Path) -> Dict[str, str]:
    values: Dict[str, str] = {}
    for raw_line in path.read_text(encoding="utf-8").splitlines():
        line = raw_line.strip()
        if not line or line.startswith("#") or "=" not in line:
            continue
        key, value = line.split("=", 1)
        values[key.strip()] = value.strip().strip('"').strip("'")
    return values


def sign(access_id: str, access_key: str, method: str, expires_ms: str) -> str:
    digest = hmac.new(
        access_key.encode("utf-8"),
        f"{access_id}{method}{expires_ms}".encode("utf-8"),
        hashlib.sha1,
    ).digest()
    return base64.b64encode(digest).decode("ascii")


def api_get(api_class: str, method: str, params: Dict[str, str]) -> bytes:
    creds = load_env(LOCAL / "labarchives.env")
    expires_ms = f"{int(time.time())}000"
    query = {
        **params,
        "akid": creds["LABARCHIVES_GOV_LOGIN_ID"],
        "expires": expires_ms,
        "sig": sign(creds["LABARCHIVES_GOV_LOGIN_ID"], creds["LABARCHIVES_GOV_ACCESS_KEY"], method, expires_ms),
    }
    url = f"{BASE_URL}/api/{api_class}/{method}?{parse.urlencode(query)}"
    req = request.Request(url, headers={"User-Agent": "elnla-seed/0.1"})
    with request.urlopen(req, timeout=60) as response:
        return response.read()


def api_post_form(api_class: str, method: str, query_params: Dict[str, str], form: Dict[str, str]) -> bytes:
    creds = load_env(LOCAL / "labarchives.env")
    expires_ms = f"{int(time.time())}000"
    query = {
        **query_params,
        "akid": creds["LABARCHIVES_GOV_LOGIN_ID"],
        "expires": expires_ms,
        "sig": sign(creds["LABARCHIVES_GOV_LOGIN_ID"], creds["LABARCHIVES_GOV_ACCESS_KEY"], method, expires_ms),
    }
    url = f"{BASE_URL}/api/{api_class}/{method}?{parse.urlencode(query)}"
    req = request.Request(
        url,
        data=parse.urlencode(form).encode("utf-8"),
        headers={
            "User-Agent": "elnla-seed/0.1",
            "Content-Type": "application/x-www-form-urlencoded",
        },
    )
    with request.urlopen(req, timeout=60) as response:
        return response.read()


def api_post_bytes(api_class: str, method: str, query_params: Dict[str, str], payload: bytes) -> bytes:
    creds = load_env(LOCAL / "labarchives.env")
    expires_ms = f"{int(time.time())}000"
    query = {
        **query_params,
        "akid": creds["LABARCHIVES_GOV_LOGIN_ID"],
        "expires": expires_ms,
        "sig": sign(creds["LABARCHIVES_GOV_LOGIN_ID"], creds["LABARCHIVES_GOV_ACCESS_KEY"], method, expires_ms),
    }
    url = f"{BASE_URL}/api/{api_class}/{method}?{parse.urlencode(query)}"
    req = request.Request(
        url,
        data=payload,
        headers={
            "User-Agent": "elnla-seed/0.1",
            "Content-Type": "application/octet-stream",
        },
    )
    with request.urlopen(req, timeout=120) as response:
        return response.read()


def xml_text(xml: bytes, *paths: str) -> str:
    root = ET.fromstring(xml)
    for path in paths:
        value = root.findtext(path)
        if value:
            return value
    raise RuntimeError(f"Could not find any of {paths} in response")


def create_notebook(uid: str) -> Tuple[str, str]:
    stamp = time.strftime("%Y-%m-%d %H:%M:%S")
    name = f"ELNLA Integration Test {stamp}"
    xml = api_get(
        "notebooks",
        "create_notebook",
        {
            "uid": uid,
            "name": name,
            "initial_folders": "Empty",
            "site_notebook_id": "ELNLA-INTEGRATION-TEST",
        },
    )
    response_path = LOCAL / "create_integration_notebook_response.xml"
    response_path.write_bytes(xml)
    os.chmod(response_path, 0o600)
    try:
        nbid = xml_text(xml, ".//notebook/id", ".//id")
    except RuntimeError:
        notebooks = refresh_notebooks(uid)
        for notebook_name, notebook_id, _ in notebooks:
            if notebook_name == name:
                nbid = notebook_id
                break
        else:
            raise
    return name, nbid


def refresh_notebooks(uid: str) -> list[Tuple[str, str, str]]:
    xml = api_get("users", "user_info_via_id", {"uid": uid})
    refresh_path = LOCAL / "user_info_via_id_refresh.xml"
    refresh_path.write_bytes(xml)
    os.chmod(refresh_path, 0o600)
    root = ET.fromstring(xml)
    rows: list[Tuple[str, str, str]] = []
    for nb in root.findall("./notebooks/notebook"):
        rows.append((nb.findtext("name") or "", nb.findtext("id") or "", nb.findtext("is-default") or ""))
    notebooks_path = LOCAL / "notebooks.tsv"
    with notebooks_path.open("w", encoding="utf-8", newline="") as handle:
        writer = csv.writer(handle, delimiter="\t")
        writer.writerow(["name", "nbid", "is_default"])
        writer.writerows(rows)
    os.chmod(notebooks_path, 0o600)
    return rows


def insert_node(uid: str, nbid: str, parent: str, label: str, is_folder: bool) -> str:
    xml = api_get(
        "tree_tools",
        "insert_node",
        {
            "uid": uid,
            "nbid": nbid,
            "parent_tree_id": parent,
            "display_text": label,
            "is_folder": "true" if is_folder else "false",
        },
    )
    time.sleep(1)
    return xml_text(xml, ".//tree-id")


def add_entry(uid: str, nbid: str, pid: str, part_type: str, entry_data: str) -> str:
    xml = api_post_form(
        "entries",
        "add_entry",
        {},
        {
            "uid": uid,
            "nbid": nbid,
            "pid": pid,
            "part_type": part_type,
            "entry_data": entry_data,
        },
    )
    time.sleep(1)
    return xml_text(xml, ".//eid")


def add_comment(uid: str, eid: str, comment: str) -> None:
    api_post_form(
        "entries",
        "add_comment",
        {},
        {
            "uid": uid,
            "eid": eid,
            "comment_data": comment,
        },
    )
    time.sleep(1)


def add_attachment(uid: str, nbid: str, pid: str, path: Path, caption: str) -> str:
    xml = api_post_bytes(
        "entries",
        "add_attachment",
        {
            "uid": uid,
            "nbid": nbid,
            "pid": pid,
            "filename": path.name,
            "caption": caption,
        },
        path.read_bytes(),
    )
    time.sleep(1)
    return xml_text(xml, ".//eid")


def write_fixture_files(target: Path) -> Iterable[Tuple[Path, str]]:
    target.mkdir(parents=True, exist_ok=True)
    fixtures: Dict[str, str | bytes] = {
        "qpcr_results.csv": "sample,target,ct,tm\nA01,ACTB,18.4,82.1\nA02,GAPDH,19.1,81.7\nB01,IL6,31.2,79.4\n",
        "sample_manifest.tsv": "sample_id\torganism\ttissue\ttreatment\nS001\tHomo sapiens\tPBMC\tcontrol\nS002\tHomo sapiens\tPBMC\tLPS 4h\n",
        "amplicon.fasta": ">ELNLA_amplicon_ACTB\nATGGATGATGATATCGCCGCGCTCGTCGTCGACAACGGCTCCGGCATGTGCAAGGCCGGCTTCGCG\n",
        "variant_panel.vcf": "##fileformat=VCFv4.2\n#CHROM\tPOS\tID\tREF\tALT\tQUAL\tFILTER\tINFO\n7\t140453136\tBRAF_V600E\tA\tT\t99\tPASS\tGENE=BRAF\n",
        "targets.bed": "chr7\t140453100\t140453200\tBRAF_amplicon\nchr12\t25398280\t25398380\tKRAS_amplicon\n",
        "plasmid.gb": "LOCUS       ELNLA_TEST       120 bp    DNA     circular SYN 14-MAY-2026\nFEATURES             Location/Qualifiers\n     promoter        1..30\n     CDS             31..90\nORIGIN\n        1 atggccattg taatgggccg ctgaaagggt gcccgacgaa cgttactgac gactgacgac\n//\n",
        "assay_metadata.json": json.dumps(
            {
                "project": "ELNLA integration test",
                "assay": "qPCR + sequencing handoff",
                "biosafety_level": "BSL-2",
                "controls": ["NTC", "positive control", "extraction blank"],
            },
            indent=2,
        ),
        "instrument_run.xml": "<run><instrument>QuantStudio</instrument><operator>ELNLA</operator><plates>1</plates></run>\n",
        "western_blot_notes.md": "# Western blot notes\n\n- Primary antibody: anti-ACTB\n- Blocking: 5% milk\n- Exposure: 30 s\n",
        "analysis_report.html": "<html><body><h1>ELNLA QC Report</h1><table><tr><th>Metric</th><th>Status</th></tr><tr><td>qPCR controls</td><td>Pass</td></tr></table></body></html>\n",
        "notebook_payload.ipynb": json.dumps(
            {
                "cells": [
                    {
                        "cell_type": "markdown",
                        "metadata": {},
                        "source": ["# ELNLA test analysis\n", "Compute delta Ct."],
                    }
                ],
                "metadata": {},
                "nbformat": 4,
                "nbformat_minor": 5,
            },
            indent=2,
        ),
        "gel_diagram.svg": "<svg xmlns=\"http://www.w3.org/2000/svg\" width=\"320\" height=\"160\"><rect width=\"320\" height=\"160\" fill=\"#111\"/><rect x=\"40\" y=\"20\" width=\"20\" height=\"115\" fill=\"#7dd3fc\" opacity=\".8\"/><rect x=\"95\" y=\"55\" width=\"20\" height=\"60\" fill=\"#fef08a\"/><rect x=\"150\" y=\"35\" width=\"20\" height=\"85\" fill=\"#fef08a\"/><text x=\"20\" y=\"150\" fill=\"white\">Mock agarose gel</text></svg>\n",
        "plate_map.txt": textwrap.dedent(
            """
            96-well plate map
            Row A: ACTB standards
            Row B: GAPDH standards
            Row C-D: treated samples
            Row E-F: controls
            """
        ).strip()
        + "\n",
        "qc_report.pdf": minimal_pdf("ELNLA integration QC report"),
        "tiny_signal.png": base64.b64decode(
            "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAwMCAO+/p9sAAAAASUVORK5CYII="
        ),
    }
    captions = {
        "qpcr_results.csv": "qPCR results table",
        "sample_manifest.tsv": "Sample manifest",
        "amplicon.fasta": "FASTA sequence",
        "variant_panel.vcf": "Variant call example",
        "targets.bed": "Target intervals",
        "plasmid.gb": "GenBank plasmid sketch",
        "assay_metadata.json": "Assay metadata JSON",
        "instrument_run.xml": "Instrument run XML",
        "western_blot_notes.md": "Western blot markdown notes",
        "analysis_report.html": "HTML analysis report",
        "notebook_payload.ipynb": "Jupyter notebook payload",
        "gel_diagram.svg": "Mock gel image SVG",
        "plate_map.txt": "Plain text plate map",
        "qc_report.pdf": "QC report PDF",
        "tiny_signal.png": "Tiny PNG signal image",
    }
    for filename, content in fixtures.items():
        path = target / filename
        if isinstance(content, bytes):
            path.write_bytes(content)
        else:
            path.write_text(content, encoding="utf-8")
        yield path, captions[filename]


def minimal_pdf(text: str) -> bytes:
    stream = f"BT /F1 18 Tf 72 720 Td ({text}) Tj ET"
    objects = [
        b"1 0 obj << /Type /Catalog /Pages 2 0 R >> endobj\n",
        b"2 0 obj << /Type /Pages /Kids [3 0 R] /Count 1 >> endobj\n",
        b"3 0 obj << /Type /Page /Parent 2 0 R /MediaBox [0 0 612 792] /Resources << /Font << /F1 4 0 R >> >> /Contents 5 0 R >> endobj\n",
        b"4 0 obj << /Type /Font /Subtype /Type1 /BaseFont /Helvetica >> endobj\n",
        f"5 0 obj << /Length {len(stream)} >> stream\n{stream}\nendstream endobj\n".encode("ascii"),
    ]
    content = bytearray(b"%PDF-1.4\n")
    offsets = [0]
    for obj in objects:
        offsets.append(len(content))
        content.extend(obj)
    xref = len(content)
    content.extend(f"xref\n0 {len(offsets)}\n0000000000 65535 f \n".encode("ascii"))
    for offset in offsets[1:]:
        content.extend(f"{offset:010d} 00000 n \n".encode("ascii"))
    content.extend(
        f"trailer << /Size {len(offsets)} /Root 1 0 R >>\nstartxref\n{xref}\n%%EOF\n".encode("ascii")
    )
    return bytes(content)


def main() -> int:
    user = load_env(LOCAL / "labarchives_user.env")
    uid = user["LABARCHIVES_GOV_UID"]
    existing_output = LOCAL / "elnla_integration_notebook.tsv"
    existing_notebooks = refresh_notebooks(uid)
    reusable = [
        (name, nbid)
        for name, nbid, _ in existing_notebooks
        if name.startswith("ELNLA Integration Test")
    ]
    if reusable and not existing_output.exists():
        notebook_name, nbid = reusable[0]
        print("Using existing dedicated integration notebook from previous create attempt.")
    else:
        notebook_name, nbid = create_notebook(uid)
        refresh_notebooks(uid)
        print("Created dedicated integration notebook.")

    folders = {
        "Assays": insert_node(uid, nbid, "0", "Assays", True),
        "Sequences": insert_node(uid, nbid, "0", "Sequences", True),
        "Imaging and Attachments": insert_node(uid, nbid, "0", "Imaging and Attachments", True),
        "Compliance": insert_node(uid, nbid, "0", "Compliance", True),
    }
    pages = {
        "Assays/qPCR run 001": insert_node(uid, nbid, folders["Assays"], "qPCR run 001", False),
        "Sequences/Amplicon and variants": insert_node(uid, nbid, folders["Sequences"], "Amplicon and variants", False),
        "Imaging and Attachments/Mixed file attachments": insert_node(uid, nbid, folders["Imaging and Attachments"], "Mixed file attachments", False),
        "Compliance/Read-only audit trail": insert_node(uid, nbid, folders["Compliance"], "Read-only audit trail", False),
    }

    eid = add_entry(uid, nbid, pages["Assays/qPCR run 001"], "heading", "qPCR run 001")
    add_comment(uid, eid, "ELNLA seed: heading/comment round trip.")
    add_entry(
        uid,
        nbid,
        pages["Assays/qPCR run 001"],
        "text entry",
        "<h2>qPCR protocol</h2><ol><li>Prepare master mix on ice.</li><li>Load 96-well plate.</li><li>Review melt curves.</li></ol><table><tr><th>Control</th><th>Status</th></tr><tr><td>NTC</td><td>Pass</td></tr></table>",
    )
    add_entry(
        uid,
        nbid,
        pages["Assays/qPCR run 001"],
        "plain text entry",
        "Observation: treated PBMC sample S002 shows delayed IL6 amplification; repeat extraction if Ct remains > 30.",
    )

    add_entry(uid, nbid, pages["Sequences/Amplicon and variants"], "heading", "Amplicon and variant notes")
    add_entry(
        uid,
        nbid,
        pages["Sequences/Amplicon and variants"],
        "text entry",
        "<p><strong>Bioinformatics handoff:</strong> FASTA, VCF, BED, and GenBank payloads are attached on the mixed attachments page.</p>",
    )

    add_entry(uid, nbid, pages["Compliance/Read-only audit trail"], "heading", "Backup viewer acceptance notes")
    add_entry(
        uid,
        nbid,
        pages["Compliance/Read-only audit trail"],
        "plain text entry",
        "Acceptance: backup app should preserve folder hierarchy, page titles, rich text, plain text, comments, and attachment metadata.",
    )

    payload_dir = LOCAL / "test_payloads"
    count = 0
    for path, caption in write_fixture_files(payload_dir):
        add_attachment(uid, nbid, pages["Imaging and Attachments/Mixed file attachments"], path, caption)
        count += 1

    output = LOCAL / "elnla_integration_notebook.tsv"
    with output.open("w", encoding="utf-8", newline="") as handle:
        writer = csv.writer(handle, delimiter="\t")
        writer.writerow(["notebook_name", "nbid", "page_path", "pid"])
        for page_path, pid in pages.items():
            writer.writerow([notebook_name, nbid, page_path, pid])
    os.chmod(output, 0o600)
    print(f"Populated dedicated notebook with {len(pages)} pages and {count} attachments.")
    print("Saved local test notebook IDs.")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
