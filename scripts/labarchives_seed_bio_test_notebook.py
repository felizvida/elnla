#!/usr/bin/env python3
"""Create and populate a dedicated LabArchives notebook for BenchVault testing.

The script reads credentials and UID from local_credentials/, creates a new
notebook when needed, adds folders/pages, writes text/rich-text content,
uploads bio-lab fixture files, and saves all returned IDs locally. It
deliberately prints only high-level progress; exact IDs stay in ignored local
files.

This is the only write-capable LabArchives helper in the repository. It is for
synthetic integration notebooks only and refuses to contact write endpoints
unless both the explicit command-line acknowledgement and environment guard are
present.
"""

from __future__ import annotations

import argparse
import base64
import csv
import hashlib
import hmac
import html
import io
import json
import os
from pathlib import Path
import struct
import textwrap
import time
from typing import Dict, Iterable, Tuple
from urllib import parse, request
from urllib.error import HTTPError, URLError
import xml.etree.ElementTree as ET
import zipfile
import zlib


ROOT = Path(__file__).resolve().parents[1]
LOCAL = ROOT / "local_credentials"
BASE_URL = "https://api.labarchives-gov.com"
API_PAUSE_SECONDS = 1.05
INTEGRATION_NOTEBOOK_PREFIX = "BenchVault Integration Test"
WRITE_GUARD_ENV = "BENCHVAULT_ALLOW_LABARCHIVES_TEST_WRITES"
WRITE_GUARD_VALUE = "YES_WRITE_SYNTHETIC_TEST_NOTEBOOK"
WRITE_ACK_FLAG = "--i-understand-this-writes-to-labarchives-test-notebook"
MUTATING_ELN_ENDPOINTS = {
    ("entries", "add_attachment"),
    ("entries", "add_comment"),
    ("entries", "add_entry"),
    ("notebooks", "create_notebook"),
    ("tree_tools", "insert_node"),
}
_WRITES_ENABLED = False
LAB_STORY = (
    "Synthetic NICHD long-running model-systems program: a lab chief-led group "
    "that has spent decades testing one coherent hypothesis: hypoxia and "
    "interferon-linked developmental stress responses shape placental function, "
    "pediatric growth, neural repair, and rehabilitation-relevant resilience. "
    "The generated record follows that axis across zebrafish, mouse, organoid, "
    "cell, molecular, chemical, and biophysical experiments."
)
NICHD_MISSION_NOTE = (
    "NICHD mission alignment: understand human development, improve reproductive "
    "health, enhance the lives of children and adolescents, and optimize "
    "abilities for all."
)
SYNTHETIC_PROJECT_ID = "NICHD-SYN-DEVSTRESS-2026"
SYNTHETIC_PROTOCOL_ID = "SYN-IACUC-DEV-0001 / SYN-IBC-CHEM-0007"
SYNTHETIC_PI = "Synthetic Lab Chief"
SYNTHETIC_OPERATOR = "BenchVault Seed Operator"
ANALYSIS_VERSION = "benchvault-fixture-analysis-v2.0.0"
SAMPLE_MATERIALS = [
    ("ZF-EMB-042", "zebrafish embryo", "24 hpf developmental morphology", "light-sheet"),
    ("ZF-LAR-117", "zebrafish larva", "5 dpf locomotor recovery", "behavior tracking"),
    ("MM-NB-031", "mouse neonate", "postnatal growth and milestone score", "phenotyping"),
    ("MM-PL-014", "mouse placenta", "junctional-zone RNA and steroid profile", "LC-MS/MS"),
    ("ORG-DEV-008", "human trophoblast organoid", "hypoxia response pilot", "confocal"),
    ("CELL-NPC-022", "neural progenitor culture", "small-molecule rescue screen", "qPCR"),
    ("PROT-001", "purified recombinant domain", "binding and stability panel", "SPR/ITC/DLS"),
    ("CMPD-418", "chemical probe dilution", "dose-response and solubility", "LC-MS/NMR"),
]
INSTRUMENT_PANEL = [
    "Leica SP8 confocal",
    "Zeiss Lightsheet Z.1",
    "BD FACSymphony A5",
    "QuantStudio 7 Flex",
    "Bio-Rad QX200 ddPCR",
    "Illumina NextSeq 2000",
    "Thermo Orbitrap Exploris LC-MS",
    "Bruker AVANCE NEO 600 MHz NMR",
    "Cytiva Biacore 8K SPR",
    "Malvern Zetasizer Ultra DLS",
    "Wyatt SEC-MALS",
    "NanoTemper Prometheus nanoDSF",
]
PROGRAM_TIMELINE = [
    ("1999", "first lab notebook series converted from paper binders"),
    ("2004", "zebrafish developmental imaging added as a rapid model system"),
    ("2011", "mouse genetics and neonatal phenotyping became the in vivo anchor"),
    ("2017", "high-throughput sequencing and cloud-adjacent analysis matured"),
    ("2021", "chemical biology and biophysical binding assays joined the pipeline"),
    ("2026", "BenchVault backup verification storyline notebook created for preservation testing"),
]


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


def read_response(req: request.Request, timeout: int) -> bytes:
    for attempt in range(4):
        try:
            with request.urlopen(req, timeout=timeout) as response:
                return response.read()
        except HTTPError as error:
            retryable = error.code in {408, 429} or 500 <= error.code < 600
            if not retryable or attempt == 3:
                raise
            wait = 2 * (attempt + 1)
            print(f"Transient LabArchives HTTP {error.code}; waiting {wait}s before retry.")
            time.sleep(wait)
        except URLError:
            if attempt == 3:
                raise
            wait = 2 * (attempt + 1)
            print(f"Transient network error; waiting {wait}s before retry.")
            time.sleep(wait)
    raise RuntimeError("unreachable retry loop")


def require_seed_write_enabled(api_class: str, method: str) -> None:
    if _WRITES_ENABLED:
        return
    raise RuntimeError(
        f"Refusing LabArchives write endpoint {api_class}::{method}. "
        f"Run only against a synthetic notebook with {WRITE_ACK_FLAG} and "
        f"{WRITE_GUARD_ENV}={WRITE_GUARD_VALUE}."
    )


def enable_seed_writes() -> None:
    global _WRITES_ENABLED
    _WRITES_ENABLED = True


def api_get(api_class: str, method: str, params: Dict[str, str]) -> bytes:
    if (api_class, method) in MUTATING_ELN_ENDPOINTS:
        require_seed_write_enabled(api_class, method)
    creds = load_env(LOCAL / "labarchives.env")
    expires_ms = f"{int(time.time())}000"
    query = {
        **params,
        "akid": creds["LABARCHIVES_GOV_LOGIN_ID"],
        "expires": expires_ms,
        "sig": sign(creds["LABARCHIVES_GOV_LOGIN_ID"], creds["LABARCHIVES_GOV_ACCESS_KEY"], method, expires_ms),
    }
    url = f"{BASE_URL}/api/{api_class}/{method}?{parse.urlencode(query)}"
    req = request.Request(url, headers={"User-Agent": "benchvault-seed/0.1"})
    return read_response(req, timeout=60)


def api_post_form(api_class: str, method: str, query_params: Dict[str, str], form: Dict[str, str]) -> bytes:
    require_seed_write_enabled(api_class, method)
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
            "User-Agent": "benchvault-seed/0.1",
            "Content-Type": "application/x-www-form-urlencoded",
        },
    )
    return read_response(req, timeout=60)


def api_post_bytes(api_class: str, method: str, query_params: Dict[str, str], payload: bytes) -> bytes:
    require_seed_write_enabled(api_class, method)
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
            "User-Agent": "benchvault-seed/0.1",
            "Content-Type": "application/octet-stream",
        },
    )
    return read_response(req, timeout=120)


def xml_text(xml: bytes, *paths: str) -> str:
    root = ET.fromstring(xml)
    for path in paths:
        value = root.findtext(path)
        if value:
            return value
    raise RuntimeError(f"Could not find any of {paths} in response")


def create_notebook(uid: str) -> Tuple[str, str]:
    stamp = time.strftime("%Y-%m-%d %H:%M:%S")
    name = f"{INTEGRATION_NOTEBOOK_PREFIX} {stamp}"
    xml = api_get(
        "notebooks",
        "create_notebook",
        {
            "uid": uid,
            "name": name,
            "initial_folders": "Empty",
            "site_notebook_id": "BenchVault-INTEGRATION-TEST",
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
    time.sleep(API_PAUSE_SECONDS)
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
    time.sleep(API_PAUSE_SECONDS)
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
    time.sleep(API_PAUSE_SECONDS)


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
    time.sleep(API_PAUSE_SECONDS)
    return xml_text(xml, ".//eid")


def write_fixture_files(target: Path) -> Iterable[Tuple[Path, str]]:
    target.mkdir(parents=True, exist_ok=True)
    fixtures: Dict[str, str | bytes] = {
        "qpcr_results.csv": "sample,target,ct,tm\nA01,ACTB,18.4,82.1\nA02,GAPDH,19.1,81.7\nB01,IL6,31.2,79.4\n",
        "sample_manifest.tsv": "sample_id\torganism\ttissue\ttreatment\nS001\tHomo sapiens\tPBMC\tcontrol\nS002\tHomo sapiens\tPBMC\tLPS 4h\nS003\tDanio rerio\tlarva\thypoxia rescue\nS004\tMus musculus\tplacenta\tinterferon stress\n",
        "amplicon.fasta": ">BenchVault_amplicon_IFIT1\nATGGATGATGATATCGCCGCGCTCGTCGTCGACAACGGCTCCGGCATGTGCAAGGCCGGCTTCGCG\n",
        "variant_panel.vcf": "##fileformat=VCFv4.2\n#CHROM\tPOS\tID\tREF\tALT\tQUAL\tFILTER\tINFO\nchr10\t910221\tIFIT1_SYN_PROMOTER\tG\tA\t99\tPASS\tGENE=IFIT1;FIXTURE=SYNTHETIC\nchr6\t3154421\tHIF1A_SYN_TAG\tC\tT\t80\tPASS\tGENE=HIF1A;FIXTURE=SYNTHETIC\n",
        "targets.bed": "chr10\t910180\t910260\tIFIT1_promoter_amplicon\nchr6\t3154380\t3154480\tHIF1A_tag_amplicon\n",
        "plasmid.gb": "LOCUS       BenchVault_TEST       120 bp    DNA     circular SYN 14-MAY-2026\nFEATURES             Location/Qualifiers\n     promoter        1..30\n     CDS             31..90\nORIGIN\n        1 atggccattg taatgggccg ctgaaagggt gcccgacgaa cgttactgac gactgacgac\n//\n",
        "assay_metadata.json": json.dumps(
            {
                "project": "BenchVault integration test",
                "assay": "qPCR + sequencing handoff",
                "biosafety_level": "BSL-2",
                "controls": ["NTC", "positive control", "extraction blank"],
            },
            indent=2,
        ),
        "instrument_run.xml": "<run><instrument>QuantStudio</instrument><operator>BenchVault</operator><plates>1</plates></run>\n",
        "western_blot_notes.md": "# Western blot notes\n\n- Primary antibody: anti-ACTB\n- Blocking: 5% milk\n- Exposure: 30 s\n",
        "analysis_report.html": "<html><body><h1>BenchVault QC Report</h1><table><tr><th>Metric</th><th>Status</th></tr><tr><td>qPCR controls</td><td>Pass</td></tr></table></body></html>\n",
        "notebook_payload.ipynb": json.dumps(
            {
                "cells": [
                    {
                        "cell_type": "markdown",
                        "metadata": {},
                        "source": ["# BenchVault test analysis\n", "Compute delta Ct."],
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
        "qc_report.pdf": minimal_pdf("BenchVault integration QC report"),
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


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(
        description="Populate the local BenchVault LabArchives integration notebook with a NICHD-style model-systems lab storyline."
    )
    parser.add_argument(
        "--fresh",
        action="store_true",
        help="Create a new integration notebook instead of reusing the latest local one.",
    )
    parser.add_argument(
        WRITE_ACK_FLAG,
        dest="acknowledge_labarchives_writes",
        action="store_true",
        help="Required: confirm this run may write synthetic content to a dedicated LabArchives integration notebook.",
    )
    parser.add_argument(
        "--dry-run",
        action="store_true",
        help="Explain the write guard and exit without reading credentials or contacting LabArchives.",
    )
    return parser.parse_args()


def ensure_explicit_write_intent(args: argparse.Namespace) -> bool:
    if args.dry_run:
        print(
            "Dry run only. This helper writes synthetic folders, pages, text, comments, "
            "and attachments to a dedicated LabArchives integration notebook."
        )
        print(
            f"To run it, set {WRITE_GUARD_ENV}={WRITE_GUARD_VALUE} and pass {WRITE_ACK_FLAG}."
        )
        return False
    if not args.acknowledge_labarchives_writes:
        raise SystemExit(
            f"Refusing to contact LabArchives. This helper writes synthetic test content. "
            f"Pass {WRITE_ACK_FLAG} when you intentionally want that."
        )
    if os.environ.get(WRITE_GUARD_ENV) != WRITE_GUARD_VALUE:
        raise SystemExit(
            f"Refusing to contact LabArchives. Set {WRITE_GUARD_ENV}={WRITE_GUARD_VALUE} "
            "only for an intentional synthetic test-notebook population run."
        )
    enable_seed_writes()
    return True


def load_existing_integration_notebook() -> Tuple[str, str] | None:
    output = LOCAL / "benchvault_integration_notebook.tsv"
    if not output.exists():
        return None
    with output.open("r", encoding="utf-8", newline="") as handle:
        reader = csv.DictReader(handle, delimiter="\t")
        for row in reader:
            name = row.get("notebook_name", "").strip()
            nbid = row.get("nbid", "").strip()
            if name.startswith(INTEGRATION_NOTEBOOK_PREFIX) and nbid:
                return name, nbid
    return None


def notebook_choice(uid: str, fresh: bool) -> Tuple[str, str]:
    if not fresh:
        local = load_existing_integration_notebook()
        if local is not None:
            print("Reusing local dedicated integration notebook.")
            return local
        reusable = [
            (name, nbid)
            for name, nbid, _ in refresh_notebooks(uid)
            if name.startswith(INTEGRATION_NOTEBOOK_PREFIX)
        ]
        if reusable:
            reusable.sort(reverse=True)
            print("Reusing latest integration notebook discovered through LabArchives.")
            return reusable[0]

    notebook_name, nbid = create_notebook(uid)
    refresh_notebooks(uid)
    print("Created dedicated integration notebook.")
    return notebook_name, nbid


def png_bytes(width: int, height: int, pixel) -> bytes:
    raw = bytearray()
    for y in range(height):
        raw.append(0)
        for x in range(width):
            raw.extend(pixel(x, y))

    def chunk(tag: bytes, data: bytes) -> bytes:
        body = tag + data
        crc = zlib.crc32(body) & 0xFFFFFFFF
        return struct.pack(">I", len(data)) + body + struct.pack(">I", crc)

    return (
        b"\x89PNG\r\n\x1a\n"
        + chunk(b"IHDR", struct.pack(">IIBBBBB", width, height, 8, 2, 0, 0, 0))
        + chunk(b"IDAT", zlib.compress(bytes(raw), 9))
        + chunk(b"IEND", b"")
    )


def plate_heatmap_png() -> bytes:
    def pixel(x: int, y: int) -> tuple[int, int, int]:
        col = min(11, max(0, x // 16))
        row = min(7, max(0, y // 16))
        value = (col * 17 + row * 29) % 255
        if x % 16 in {0, 1} or y % 16 in {0, 1}:
            return (235, 245, 240)
        return (20, 90 + value // 3, 85 + value // 4)

    return png_bytes(192, 128, pixel)


def microscopy_png() -> bytes:
    centers = [(38, 44, 20), (94, 63, 25), (147, 42, 18), (176, 94, 22)]

    def pixel(x: int, y: int) -> tuple[int, int, int]:
        base = (8, 18, 28)
        for cx, cy, radius in centers:
            distance = ((x - cx) ** 2 + (y - cy) ** 2) ** 0.5
            if distance < radius:
                edge = int(max(0, 180 - distance * 5))
                return (40, min(255, 80 + edge), min(255, 105 + edge))
            if distance < radius + 4:
                return (55, 110, 150)
        return base

    return png_bytes(220, 132, pixel)


def flow_density_png() -> bytes:
    def pixel(x: int, y: int) -> tuple[int, int, int]:
        gate = 40 < x < 170 and 30 < y < 110
        cloud = ((x - 105) ** 2) / 3600 + ((y - 70) ** 2) / 900
        if abs(x - 40) < 2 or abs(y - 110) < 2:
            return (55, 70, 70)
        if gate and (abs(x - 40) < 2 or abs(x - 170) < 2 or abs(y - 30) < 2 or abs(y - 110) < 2):
            return (230, 180, 35)
        if cloud < 1.0:
            heat = int(220 * (1 - cloud))
            return (20 + heat, 80 + heat // 3, 120)
        return (238, 246, 242)

    return png_bytes(220, 140, pixel)


def deterministic_binary(size: int, seed: int = 17) -> bytes:
    return bytes(((index * 37 + seed) % 256 for index in range(size)))


def zip_bytes(files: Dict[str, str | bytes]) -> bytes:
    buffer = io.BytesIO()
    with zipfile.ZipFile(buffer, "w", compression=zipfile.ZIP_DEFLATED) as archive:
        for filename, content in files.items():
            payload = content if isinstance(content, bytes) else content.encode("utf-8")
            archive.writestr(filename, payload)
    return buffer.getvalue()


def write_large_fixture_files(target: Path, run_slug: str) -> list[Tuple[Path, str]]:
    fixtures = list(write_fixture_files(target))
    run_dir = target / run_slug
    run_dir.mkdir(parents=True, exist_ok=True)

    gene_rows = ["gene\tS001_ctrl\tS002_lps4h\tS003_lps8h\tS004_rescue"]
    for index in range(1, 81):
        gene_rows.append(
            f"GENE{index:04d}\t{80 + index}\t{92 + index * 2}\t{71 + index % 17}\t{88 + index % 23}"
        )

    qpcr_rows = ["well,sample,target,ct,tm,flag"]
    for row in "ABCDEFGHIJKLMNOP":
        for col in range(1, 25):
            target_name = ["ACTB", "GAPDH", "IL6", "TNF", "CXCL10", "IFNB1"][(col + ord(row)) % 6]
            qpcr_rows.append(
                f"{row}{col:02d},S{(col % 12) + 1:03d},{target_name},{18 + ((col * 7 + ord(row)) % 180) / 10:.1f},{78 + (col % 9) / 2:.1f},{'review' if col % 17 == 0 else 'ok'}"
            )

    flow_rows = ["event_id,fsc_a,ssc_a,fitc_a,pe_a,gate_hint"]
    for index in range(1, 501):
        flow_rows.append(
            f"{index},{42000 + index * 13},{18000 + index * 7},{700 + (index * 19) % 9000},{500 + (index * 23) % 7000},{'singlet_live' if index % 5 else 'review'}"
        )

    freezer_rows = ["box,position,sample,contents,temperature_c"]
    for box in range(1, 5):
        for position in range(1, 25):
            freezer_rows.append(
                f"BOX-{box:02d},{position:02d},S{box:02d}-{position:02d},RNA aliquot and cDNA backup,-80"
            )

    zebrafish_rows = ["embryo_id,line,stage_hpf,standard_length_mm,heart_rate_bpm,phenotype"]
    for index in range(1, 49):
        zebrafish_rows.append(
            f"ZF{index:03d},dev-rescue-A,{24 + index % 72},{2.8 + (index % 11) / 10:.1f},{122 + index % 18},{'edema_review' if index % 13 == 0 else 'typical'}"
        )

    mouse_rows = ["cage_id,dam_id,litter,pup_id,pnd,weight_g,righting_reflex_s,genotype_call"]
    for index in range(1, 37):
        mouse_rows.append(
            f"MC{1 + index // 6:03d},DAM{index % 8:02d},L{index % 5:02d},PUP{index:03d},{index % 14},{1.2 + index / 20:.2f},{4 + index % 9},{'het' if index % 3 else 'wt'}"
        )

    compound_rows = ["compound_id,plate,well,target_pathway,stock_mm,solubility_flag,developmental_window"]
    for index in range(1, 73):
        compound_rows.append(
            f"CMPD{index:04d},DEVRES-A,{chr(65 + (index - 1) // 12)}{((index - 1) % 12) + 1:02d},{['SHH', 'WNT', 'BMP', 'RA', 'mTOR', 'mitochondrial'][index % 6]},{10 + index % 5},"
            f"{'precipitate_review' if index % 19 == 0 else 'clear'},"
            f"{['gastrulation', 'neurulation', 'placentation', 'neonatal repair'][index % 4]}"
        )

    lc_ms_rows = ["feature_id,rt_min,mz,intensity,annotation,model_context"]
    for index in range(1, 91):
        lc_ms_rows.append(
            f"F{index:04d},{1.5 + index / 20:.2f},{120 + index * 1.337:.4f},{200000 + index * 5111},"
            f"{['steroid-like', 'lipid mediator', 'retinoid-like', 'unknown'][index % 4]},"
            f"{['mouse placenta', 'zebrafish larva', 'organoid media'][index % 3]}"
        )

    spr_rows = ["cycle,ligand_nm,analyte_nm,ka_1_per_ms,kd_1_per_s,rmax_ru,fit_note"]
    for index in range(1, 25):
        spr_rows.append(
            f"{index},{50 + index * 5},{3.125 * (1 + index % 8):.3f},{1.1e5 + index * 1200:.1f},{0.002 + index / 10000:.4f},{85 + index % 12},{'mass_transport_review' if index % 7 == 0 else 'global_fit_ok'}"
        )

    dls_rows = ["condition,temperature_c,z_average_nm,pdi,derived_count_rate_kcps,comment"]
    for index, condition in enumerate(["PBS", "HEPES", "low_salt", "high_salt", "compound_A", "compound_B"], start=1):
        dls_rows.append(
            f"{condition},{20 + index * 5},{8.5 + index / 3:.2f},{0.08 + index / 100:.2f},{180 + index * 17},{'stable' if index < 5 else 'aggregation_onset'}"
        )

    accession_rows = [
        "sample_id,model,source_or_parent,sex_or_stage,collection_time,storage,downstream_assay,disposition"
    ]
    for sample_id, material, context, method in SAMPLE_MATERIALS:
        accession_rows.append(
            f"{sample_id},{material},{context},{'synthetic stage' if sample_id.startswith('ZF') else 'synthetic sex balanced'},2026-05-14T09:{len(sample_id):02d}:00Z,archive box DEV-{len(sample_id):02d},{method},retain for backup fixture"
        )

    control_rows = [
        "assay,control_id,type,expected_result,observed_result,disposition",
        "RT-qPCR,NTC-001,no-template,no amplification,no amplification,pass",
        "RT-qPCR,NORT-001,no-RT,no amplification,late background at Ct 38,review",
        "LC-MS,BLANK-001,solvent blank,no target peaks,no target peaks,pass",
        "LC-MS,QCP-001,pooled QC,stable retention time,rt drift 0.03 min,pass",
        "Flow,FMO-FITC,fluorescence-minus-one,gate boundary control,gate verified,pass",
        "Microscopy,NO-PRIMARY-001,no-primary antibody,low background,low background,pass",
        "SPR,REF-CH1,reference channel,no specific binding,subtracted,pass",
        "ITC,BUFFER-001,buffer blank,flat heats,flat heats,pass",
        "DLS,VEHICLE-001,vehicle control,monodisperse,monodisperse,pass",
    ]

    reagent_rows = [
        "reagent_id,reagent_type,vendor_catalog,lot,storage,working_concentration,review",
        "AB-STAT1-001,antibody,ExampleBio-9172,LOT-SYN-A1,4C,1:1000,western blot primary",
        "AB-GFAP-002,antibody,ExampleBio-4401,LOT-SYN-G2,4C,1:500,imaging marker",
        "PR-IFIT1-F,primer,ExampleOligo,LOT-P100,-20C,400 nM,qPCR forward",
        "PR-IFIT1-R,primer,ExampleOligo,LOT-P101,-20C,400 nM,qPCR reverse",
        "CMPD0042,compound,ExampleChem-0042,BATCH-C42,-20C in DMSO,10 mM,advance",
        "MAT-ORG-001,matrix,ExampleMatrix-GFR,LOT-M55,-80C,undiluted,organoid culture",
        "PLASMID-DEV-IFN,plasmid,synthetic construct,v3.2,-20C,50 ng/uL,sequence verified",
    ]

    animal_rows = [
        "record_id,model,strain_or_line,parent_or_clutch,stage_or_age,sex,housing_or_incubation,endpoint,synthetic_protocol"
    ]
    for index in range(1, 13):
        animal_rows.append(
            f"ZF-AUD-{index:03d},zebrafish,devstress-ifn-reporter,clutch C{index % 4 + 1},"
            f"{24 + index * 4} hpf,mixed,28.5C embryo medium,morphology imaging,{SYNTHETIC_PROTOCOL_ID}"
        )
    for index in range(1, 13):
        animal_rows.append(
            f"MM-AUD-{index:03d},mouse,C57BL/6J synthetic cross,DAM{index % 5 + 1},PND{index % 14},"
            f"{'F' if index % 2 else 'M'},ventilated rack synthetic room,neonatal milestone score,{SYNTHETIC_PROTOCOL_ID}"
        )

    demux_rows = [
        "sample_id,index_reads,percent_q30,assigned_reads,warning",
        "S001,250000,94.2,238120,none",
        "S002,240000,92.8,221442,adapter_content_review",
        "S003,232000,93.5,219003,none",
        "S004,210000,90.1,183991,low_depth_review",
    ]

    compensation_rows = [
        "channel,FITC,PE,APC,BV421",
        "FITC,1.000,0.041,0.002,0.004",
        "PE,0.018,1.000,0.011,0.006",
        "APC,0.001,0.009,1.000,0.003",
        "BV421,0.004,0.003,0.001,1.000",
    ]

    extra: Dict[str, str | bytes] = {
        "rna_seq_counts_matrix.tsv": "\n".join(gene_rows) + "\n",
        "qpcr_raw_export_384well.csv": "\n".join(qpcr_rows) + "\n",
        "flow_events_subset.csv": "\n".join(flow_rows) + "\n",
        "freezer_box_inventory.csv": "\n".join(freezer_rows) + "\n",
        "zebrafish_embryo_morphometrics.csv": "\n".join(zebrafish_rows) + "\n",
        "mouse_neonatal_phenotyping.csv": "\n".join(mouse_rows) + "\n",
        "compound_library_plate_map.csv": "\n".join(compound_rows) + "\n",
        "lc_ms_feature_table.csv": "\n".join(lc_ms_rows) + "\n",
        "spr_binding_kinetics.csv": "\n".join(spr_rows) + "\n",
        "dls_stability_panel.csv": "\n".join(dls_rows) + "\n",
        "itc_binding_summary.csv": "injection,protein_um,ligand_um,delta_h_kcal_mol,stoichiometry,kd_um,comment\n1,20,200,-6.2,0.92,1.8,good baseline\n2,20,200,-5.9,0.89,2.1,repeat recommended\n",
        "nmr_peak_list.csv": "peak_id,ppm,integral,assignment,review\nP01,7.21,1.00,aromatic,ok\nP02,3.84,2.10,methoxy,ok\nP03,1.28,3.02,alkyl,solvent_overlap_review\n",
        "sec_mals_trace.csv": "time_min,uv280_mau,light_scattering,derived_mw_kda\n5.0,4.2,120,42.1\n5.5,9.8,288,42.4\n6.0,3.1,95,41.9\n",
        "nano_dsf_thermal_shift.csv": "sample,compound,tm_c,delta_tm_c,aggregation_onset_c\nPROT-001,DMSO,48.2,0.0,62.4\nPROT-001,CMPD0042,52.7,4.5,64.8\n",
        "zebrafish_behavior_tracking.csv": "larva_id,seconds,total_distance_mm,bout_count,mean_velocity_mm_s\nZF-LAR-001,600,184.2,77,0.31\nZF-LAR-002,600,231.9,91,0.39\n",
        "mouse_histology_scoring.csv": "slide_id,tissue,stain,region,score,reviewer_note\nHIS-001,placenta,H&E,junctional_zone,2,synthetic fixture\nHIS-002,brain,IHC,corpus_callosum,1,synthetic fixture\n",
        "organoid_growth_curve.csv": "day,condition,organoid_count,median_diameter_um,branching_score\n0,control,96,82,0\n3,control,88,144,2\n3,hypoxia,84,131,3\n",
        "metabolomics_sample_manifest.tsv": "sample_id\tmodel\tmatrix\textraction_solvent\tinstrument_method\nMM-PL-014\tmouse placenta\ttissue\t80pct_methanol\tlc_ms_dev_rescue\nZF-LAR-117\tzebrafish larva\twhole larva\tacetonitrile_water\tlc_ms_dev_rescue\n",
        "sample_accession_ledger.csv": "\n".join(accession_rows) + "\n",
        "assay_control_matrix.csv": "\n".join(control_rows) + "\n",
        "reagent_lot_ledger.csv": "\n".join(reagent_rows) + "\n",
        "animal_model_provenance.csv": "\n".join(animal_rows) + "\n",
        "sequencing_demultiplex_summary.csv": "\n".join(demux_rows) + "\n",
        "flow_compensation_matrix.csv": "\n".join(compensation_rows) + "\n",
        "western_blot_densitometry.csv": "lane,target,background_corrected_intensity,normalized_to_actb\n1,STAT1,18333,0.91\n2,pSTAT1,24119,1.38\n3,ACTB,19811,1.00\n",
        "illumina_sample_sheet.csv": "[Header],,,,,\nIEMFileVersion,5,,,,\n[Data],,,,,\nSample_ID,Sample_Name,index,index2,Description,Project\nS001,PBMC_control,ATCACG,CGATGT,control,BenchVault\nS002,PBMC_LPS4h,CGATGT,TGACCA,treated,BenchVault\nS003,ZF_larva_hypoxia,TTAGGC,ACAGTG,zebrafish,BenchVault\nS004,Mouse_placenta_rescue,TGACCA,GCCAAT,mouse_placenta,BenchVault\n",
        "primer_inventory.csv": "primer_id,target,sequence,tm_c,storage_box\nP001,IL6_F,ACTCACCTCTTCAGAACGAATTG,60.1,BOX-1\nP002,IL6_R,CCATCTTTGGAAGGTTCAGGTTG,60.4,BOX-1\n",
        "crispr_guides.tsv": "guide_id\tgene\tsequence\tpam\toff_target_review\nG001\tSTAT1\tGAGTACATGCTGACCCACAA\tGGG\tpass\nG002\tIRF1\tTCCACCTCTCACCAAGATCC\tAGG\treview_required\n",
        "elisa_plate_readout.csv": "well,standard_pg_ml,od450,od570_corrected\nA01,1000,2.110,2.010\nA02,500,1.532,1.432\nB01,,0.771,0.690\n",
        "nanodrop_export.csv": "sample,ng_ul,260_280,260_230,comment\nRNA_S001,512.4,2.05,2.21,excellent\nRNA_S002,288.1,1.97,1.83,cleanup optional\n",
        "cell_counter_export.csv": "sample,total_cells,viability_percent,dilution\nPBMC_S001,1480000,96.2,2\nPBMC_S002,1315000,91.8,2\n",
        "fastq_tiny_lane001.fastq": "@SEQ_ID_1\nGATTTGGGGTTCAAAGCAGTATCGATCAAATAGTAAAT\n+\nIIIIIIIIIIIIIIIIIIIIIIIIIIIIIIIIIIIIII\n@SEQ_ID_2\nCTGATCGTAGCTAGCTAGGATCGATCGATCGATCGAA\n+\nIIIIIIIIIIIIIIIIIIIIIIIIIIIIIIIIIIIII\n",
        "reference_transcript.fa": ">NM_BenchVault_TEST cytokine response transcript\nATGGCTGCTGCTGAACTGACCTTGACCGAGGAGGACCTGAGCTTCCAGGACATG\n",
        "gene_models.gff3": "##gff-version 3\nchrTest\tBenchVault\tgene\t100\t950\t.\t+\t.\tID=gene0001;Name=BenchVault1\nchrTest\tBenchVault\texon\t100\t220\t.\t+\t.\tParent=gene0001\n",
        "construct_map.gb": "LOCUS       BenchVault_STORY     620 bp    DNA     circular SYN 14-MAY-2026\nFEATURES             Location/Qualifiers\n     promoter        1..100\n     misc_feature    101..160\n     CDS             161..520\nORIGIN\n        1 atggccattgtaatgggccgctgaaagggtgcccgacgaacgttactgacgactgacgac\n//\n",
        "analysis_manifest.json": json.dumps(
            {
                "run": run_slug,
                "program_story": LAB_STORY,
                "pipelines": [
                    "fastqc",
                    "multiqc",
                    "salmon",
                    "deseq2",
                    "cellprofiler",
                    "skyline",
                    "custom-qc",
                ],
                "expected_shared_fixture_files": 97,
                "expected_page_specific_attachments": len(page_blueprints()),
                "expected_total_attachment_uploads": 97 + len(page_blueprints()),
                "storage": {
                    "primary": "example.org/project-storage/benchvault/nichd-model-systems-storyline",
                    "cold_archive": "s3://example-benchvault-cold-archive/nichd-model-systems-storyline",
                },
            },
            indent=2,
        ),
        "lims_export.json": json.dumps(
            {
                "samples": [
                    {"sample_id": "S001", "matrix": "PBMC", "consent": "not_applicable_test_fixture"},
                    {"sample_id": "S002", "matrix": "PBMC", "consent": "not_applicable_test_fixture"},
                    {"sample_id": "ZF-EMB-042", "matrix": "zebrafish embryo", "protocol": "synthetic_fixture"},
                    {"sample_id": "MM-PL-014", "matrix": "mouse placenta", "protocol": "synthetic_fixture"},
                    {"sample_id": "ORG-DEV-008", "matrix": "trophoblast organoid", "protocol": "synthetic_fixture"},
                ],
                "chain_of_custody": ["received", "accessioned", "extracted", "sequenced"],
            },
            indent=2,
        ),
        "cloud_storage_manifest.json": json.dumps(
            {
                "links": [
                    "https://example.org/benchvault/nichd-model-systems-storyline/raw",
                    "https://osf.io/example-benchvault-placeholder/",
                    "https://www.ncbi.nlm.nih.gov/geo/query/acc.cgi?acc=GSE000000",
                    "globus://example-endpoint/benchvault/nichd-model-systems-storyline",
                ]
            },
            indent=2,
        ),
        "qc_flags.json": json.dumps(
            {"flags": ["low RNA yield S002", "review melt curve B17", "rerun flow compensation if PE spillover persists"]},
            indent=2,
        ),
        "instrument_metadata.xml": "<instrument><name>QuantStudio 7 Flex</name><plate>384</plate><operator>BenchVault seed</operator><runMode>test-fixture</runMode></instrument>\n",
        "microscope_metadata.ome.xml": "<OME><Image ID=\"Image:0\"><Pixels DimensionOrder=\"XYZCT\" Type=\"uint16\" SizeX=\"1024\" SizeY=\"1024\" SizeZ=\"1\" SizeC=\"3\" SizeT=\"1\"/></Image></OME>\n",
        "light_sheet_metadata.ome.xml": "<OME><Instrument ID=\"Instrument:Lightsheet\"><Microscope Manufacturer=\"Zeiss\" Model=\"Lightsheet Z.1\"/></Instrument><Image ID=\"Image:ZF-5dpf\"><Pixels DimensionOrder=\"XYZCT\" Type=\"uint16\" SizeX=\"2048\" SizeY=\"2048\" SizeZ=\"120\" SizeC=\"2\" SizeT=\"16\"/></Image></OME>\n",
        "mass_spec_method.xml": "<method><instrument>Orbitrap Exploris</instrument><ionization>ESI</ionization><polarity>positive-negative switching</polarity><column>C18 2.1x100mm</column><gradientMinutes>18</gradientMinutes></method>\n",
        "nmr_method.xml": "<nmr><instrument>Bruker AVANCE NEO</instrument><fieldMHz>600</fieldMHz><probe>TCI cryoprobe</probe><experiment>1H CPMG water suppression</experiment></nmr>\n",
        "RunInfo.xml": "<RunInfo><Run Id=\"NICHD_STORY_RUN\"><Flowcell>BenchVault0001</Flowcell><Instrument>NextSeq2000</Instrument></Run></RunInfo>\n",
        "RunParameters.xml": "<RunParameters><Read1>59</Read1><Index1>8</Index1><Index2>8</Index2><Read2>59</Read2><Chemistry>synthetic</Chemistry></RunParameters>\n",
        "interop_summary.csv": "metric,value,status\ncluster_density,188 K/mm2,pass\npercent_q30,92.6,pass\nindex_hopping,0.18,review\n",
        "developmental_stress_panel.mzML": "<?xml version=\"1.0\" encoding=\"UTF-8\"?><mzML><run id=\"synthetic-lcms\"><spectrumList count=\"2\"><spectrum id=\"scan=1\"/><spectrum id=\"scan=2\"/></spectrumList></run></mzML>\n",
        "biacore_sensorgram_export.csv": "time_s,flow_cell_1_ru,flow_cell_2_ru,subtracted_ru\n0,0.1,0.0,0.1\n30,12.4,1.1,11.3\n60,48.2,3.2,45.0\n180,9.8,1.0,8.8\n",
        "microcal_itc_raw_heats.csv": "injection,seconds,raw_heat_ucal,baseline_ucal\n1,120,-2.14,0.02\n2,240,-1.88,0.01\n3,360,-1.44,0.02\n",
        "dls_autocorrelation_export.csv": "lag_us,g2_minus_1,fit_residual\n1,0.991,0.001\n10,0.782,-0.002\n100,0.311,0.004\n1000,0.042,-0.001\n",
        "qPCR_raw_run.EDS": deterministic_binary(4096, seed=42),
        "flow_panel_export.fcs": b"FCS3.1    58  210  211  420  421  421TEXT       $TOT/12/$PAR/4/$P1N/FSC-A/$P2N/SSC-A/$P3N/FITC-A/$P4N/PE-A/",
        "light_sheet_stack_preview.ome.tiff": b"II*\x00\x08\x00\x00\x00BenchVault synthetic OME-TIFF preview payload\n",
        "confocal_raw_placeholder.czi": b"ZISRAWFILE synthetic CZI placeholder for backup restore testing\n",
        "legacy_lif_placeholder.LIF": b"Leica LIF synthetic placeholder with uppercase extension\n",
        "bruker_nmr_raw_stub.zip": zip_bytes(
            {
                "exp/10/acqus": "##TITLE=BenchVault synthetic NMR acquisition\n##$SFO1=600.13\n",
                "exp/10/pdata/1/procs": "##TITLE=processed synthetic spectrum\n##$SI=65536\n",
                "README.txt": "Generated placeholder for Bruker-style directory restore testing.\n",
            }
        ),
        "moderately_large_original_payload.bin": deterministic_binary(262144, seed=91),
        "README_NO_EXTENSION.txt": "LabArchives accepted no-extension files during testing, but the backup archive omitted those originals. The seed now uses a text suffix so full-size backup verification can pass while documenting the edge case.\n",
        "compound plate map (review copy).CSV": "well,compound,reason\nA01,CMPD0042,duplicate uppercase extension and spaces\n",
        "very_long_filename_for_hypoxia_interferon_developmental_stress_response_backup_restore_validation_attachment_20260514_version_0001.tsv": "field\tvalue\npurpose\tlong filename restore test\n",
        "master_protocol.md": "# Master molecular biology protocol\n\n## Modules\n\n1. Cell thaw and rest\n2. LPS stimulation\n3. RNA extraction\n4. Library prep\n5. Bioinformatics handoff\n\nAll steps are generated test content for BenchVault backup verification.\n",
        "program_timeline.md": "# Synthetic NICHD lab timeline\n\n"
        + "\n".join(f"- {year}: {event}" for year, event in PROGRAM_TIMELINE)
        + "\n\n"
        + NICHD_MISSION_NOTE
        + "\n",
        "animal_protocol_crosswalk.md": "# Synthetic animal-study crosswalk\n\n- Zebrafish embryo and larval imaging: developmental morphology and recovery readouts.\n- Mouse colony and neonatal phenotyping: growth, placental tissue, and milestone observations.\n- No real animal protocol numbers, cage IDs, or personnel names are included; all rows are generated fixtures.\n",
        "capa_record.md": "# CAPA drill\n\nDeviation: temperature excursion alarm acknowledged late.\n\nCorrective action: document transfer to backup freezer, review logger export, annotate sample impact as no biological material affected in this test fixture.\n",
        "rna_seq_multiqc_report.html": "<html><body><h1>Mock MultiQC report</h1><p>All modules pass except adapter content review for S002.</p><ul><li>FastQC: pass</li><li>Salmon mapping: pass</li><li>Duplication: warning</li></ul></body></html>\n",
        "chemical_biology_screen_report.html": "<html><body><h1>Developmental-rescue chemical screen</h1><p>Mock report linking zebrafish morphology, neural progenitor rescue, and solubility review. Hits require orthogonal confirmation by LC-MS purity, NMR identity, and target-engagement assays.</p><table><tr><th>Compound</th><th>Model</th><th>Disposition</th></tr><tr><td>CMPD0042</td><td>zebrafish larva</td><td>advance to dose-response</td></tr><tr><td>CMPD0057</td><td>mouse organoid</td><td>hold for solubility</td></tr></table></body></html>\n",
        "analysis_notebook.ipynb": json.dumps(
            {
                "cells": [
                    {
                        "cell_type": "markdown",
                        "metadata": {},
                        "source": [
                            "# BenchVault NICHD model-systems stress analysis\n",
                            "Join zebrafish, mouse, organoid, sequencing, chemical, and biophysical fixture data.\n",
                        ],
                    },
                    {"cell_type": "code", "execution_count": None, "metadata": {}, "outputs": [], "source": ["counts <- read.table('rna_seq_counts_matrix.tsv')\n"]},
                ],
                "metadata": {"kernelspec": {"name": "ir", "display_name": "R"}},
                "nbformat": 4,
                "nbformat_minor": 5,
            },
            indent=2,
        ),
        "analysis_script.py": "from pathlib import Path\n\nfor path in Path('.').glob('*.csv'):\n    print(path.name)\n",
        "normalization.R": "counts <- read.delim('rna_seq_counts_matrix.tsv')\nprint(summary(counts))\n",
        "warehouse_queries.sql": "select sample_id, freezer_box, position from aliquots where project = 'BenchVault_NICHD_STORYLINE';\n",
        "workflow.yaml": "name: benchvault-nichd-storyline-fixture\nsteps:\n  - fastqc\n  - multiqc\n  - salmon\n  - deseq2\n",
        "animal_imaging_workflow.yaml": "name: model-organism-imaging-fixture\nsteps:\n  - import_ome_xml\n  - segment_embryos\n  - score_morphometry\n  - export_qc_tables\n",
        "biophysics_binding_workflow.yaml": "name: chemical-biophysics-fixture\nsteps:\n  - inspect_lc_ms_purity\n  - fit_spr_sensorgrams\n  - review_itc_heatmap\n  - compare_dls_stability\n",
        "plate_heatmap.png": plate_heatmap_png(),
        "mock_microscopy.png": microscopy_png(),
        "flow_gate_density.png": flow_density_png(),
        "western_blot_mock.svg": "<svg xmlns=\"http://www.w3.org/2000/svg\" width=\"420\" height=\"220\"><rect width=\"420\" height=\"220\" fill=\"#f7faf7\"/><rect x=\"45\" y=\"30\" width=\"36\" height=\"150\" fill=\"#111\"/><rect x=\"115\" y=\"70\" width=\"36\" height=\"90\" fill=\"#333\"/><rect x=\"185\" y=\"45\" width=\"36\" height=\"135\" fill=\"#111\"/><rect x=\"255\" y=\"95\" width=\"36\" height=\"62\" fill=\"#555\"/><text x=\"30\" y=\"205\" font-family=\"Arial\" font-size=\"18\">Mock western blot lanes</text></svg>\n",
        "gel_ladder_detailed.svg": "<svg xmlns=\"http://www.w3.org/2000/svg\" width=\"420\" height=\"220\"><rect width=\"420\" height=\"220\" fill=\"#101820\"/><g fill=\"#86efac\"><rect x=\"60\" y=\"35\" width=\"34\" height=\"8\"/><rect x=\"60\" y=\"60\" width=\"34\" height=\"8\"/><rect x=\"60\" y=\"92\" width=\"34\" height=\"8\"/><rect x=\"140\" y=\"70\" width=\"34\" height=\"8\"/><rect x=\"220\" y=\"55\" width=\"34\" height=\"8\"/><rect x=\"300\" y=\"105\" width=\"34\" height=\"8\"/></g><text x=\"25\" y=\"200\" fill=\"white\" font-family=\"Arial\" font-size=\"18\">Mock agarose gel with ladder</text></svg>\n",
        "long_protocol_summary.pdf": minimal_pdf("BenchVault large protocol summary"),
        "sample_chain_of_custody.pdf": minimal_pdf("BenchVault sample chain of custody"),
    }
    captions = {
        "rna_seq_counts_matrix.tsv": "Large RNA-seq counts matrix",
        "qpcr_raw_export_384well.csv": "384-well qPCR raw export",
        "flow_events_subset.csv": "Flow cytometry event subset",
        "freezer_box_inventory.csv": "Freezer box inventory export",
        "zebrafish_embryo_morphometrics.csv": "Zebrafish embryo morphometrics table",
        "mouse_neonatal_phenotyping.csv": "Mouse neonatal phenotyping table",
        "compound_library_plate_map.csv": "Chemical biology compound plate map",
        "lc_ms_feature_table.csv": "LC-MS feature table",
        "spr_binding_kinetics.csv": "SPR binding kinetics export",
        "dls_stability_panel.csv": "DLS stability panel",
        "itc_binding_summary.csv": "ITC binding summary",
        "nmr_peak_list.csv": "NMR peak list",
        "sec_mals_trace.csv": "SEC-MALS trace",
        "nano_dsf_thermal_shift.csv": "nanoDSF thermal shift table",
        "zebrafish_behavior_tracking.csv": "Zebrafish behavior tracking export",
        "mouse_histology_scoring.csv": "Mouse histology scoring table",
        "organoid_growth_curve.csv": "Organoid growth curve",
        "metabolomics_sample_manifest.tsv": "Metabolomics sample manifest",
        "sample_accession_ledger.csv": "Canonical sample accession ledger",
        "assay_control_matrix.csv": "Assay controls and blanks matrix",
        "reagent_lot_ledger.csv": "Reagent and lot provenance ledger",
        "animal_model_provenance.csv": "Zebrafish and mouse provenance ledger",
        "sequencing_demultiplex_summary.csv": "Sequencing demultiplex summary",
        "flow_compensation_matrix.csv": "Flow cytometry compensation matrix",
        "western_blot_densitometry.csv": "Western blot densitometry table",
        "illumina_sample_sheet.csv": "Illumina sample sheet",
        "primer_inventory.csv": "Primer inventory",
        "crispr_guides.tsv": "CRISPR guide design table",
        "elisa_plate_readout.csv": "ELISA plate readout",
        "nanodrop_export.csv": "Nanodrop RNA QC export",
        "cell_counter_export.csv": "Cell counter export",
        "fastq_tiny_lane001.fastq": "Tiny FASTQ lane fixture",
        "reference_transcript.fa": "Reference transcript FASTA",
        "gene_models.gff3": "Gene model GFF3",
        "construct_map.gb": "Construct map GenBank",
        "analysis_manifest.json": "Analysis manifest JSON",
        "lims_export.json": "LIMS export JSON",
        "cloud_storage_manifest.json": "External storage manifest",
        "qc_flags.json": "QC flags JSON",
        "instrument_metadata.xml": "Instrument metadata XML",
        "microscope_metadata.ome.xml": "Microscope OME XML metadata",
        "light_sheet_metadata.ome.xml": "Light-sheet OME XML metadata",
        "mass_spec_method.xml": "Mass spectrometry method XML",
        "nmr_method.xml": "NMR method XML",
        "RunInfo.xml": "Illumina-style RunInfo XML",
        "RunParameters.xml": "Illumina-style RunParameters XML",
        "interop_summary.csv": "Sequencing InterOp summary CSV",
        "developmental_stress_panel.mzML": "LC-MS mzML placeholder",
        "biacore_sensorgram_export.csv": "Biacore sensorgram export",
        "microcal_itc_raw_heats.csv": "MicroCal ITC raw heats export",
        "dls_autocorrelation_export.csv": "DLS autocorrelation export",
        "qPCR_raw_run.EDS": "qPCR vendor-shaped EDS placeholder",
        "flow_panel_export.fcs": "Flow cytometry FCS placeholder",
        "light_sheet_stack_preview.ome.tiff": "OME-TIFF placeholder",
        "confocal_raw_placeholder.czi": "Confocal CZI placeholder",
        "legacy_lif_placeholder.LIF": "Leica LIF uppercase-extension placeholder",
        "bruker_nmr_raw_stub.zip": "Bruker-style NMR zipped directory stub",
        "moderately_large_original_payload.bin": "Moderately large binary restore payload",
        "README_NO_EXTENSION.txt": "Documented no-extension backup limitation fixture",
        "compound plate map (review copy).CSV": "Duplicate-style filename with spaces and uppercase extension",
        "very_long_filename_for_hypoxia_interferon_developmental_stress_response_backup_restore_validation_attachment_20260514_version_0001.tsv": "Very long filename restore fixture",
        "master_protocol.md": "Master protocol Markdown",
        "program_timeline.md": "Synthetic NICHD lab timeline Markdown",
        "animal_protocol_crosswalk.md": "Synthetic animal protocol crosswalk Markdown",
        "capa_record.md": "CAPA drill Markdown",
        "rna_seq_multiqc_report.html": "Mock MultiQC HTML report",
        "chemical_biology_screen_report.html": "Chemical biology screen HTML report",
        "analysis_notebook.ipynb": "Analysis notebook payload",
        "analysis_script.py": "Python helper script",
        "normalization.R": "R normalization script",
        "warehouse_queries.sql": "Warehouse query SQL",
        "workflow.yaml": "Workflow YAML",
        "animal_imaging_workflow.yaml": "Animal imaging workflow YAML",
        "biophysics_binding_workflow.yaml": "Biophysics binding workflow YAML",
        "plate_heatmap.png": "Plate heatmap PNG",
        "mock_microscopy.png": "Mock microscopy PNG",
        "flow_gate_density.png": "Flow density PNG",
        "western_blot_mock.svg": "Mock western blot SVG",
        "gel_ladder_detailed.svg": "Detailed gel ladder SVG",
        "long_protocol_summary.pdf": "Long protocol PDF",
        "sample_chain_of_custody.pdf": "Chain-of-custody PDF",
    }

    for filename, content in extra.items():
        path = run_dir / filename
        if isinstance(content, bytes):
            path.write_bytes(content)
        else:
            path.write_text(content, encoding="utf-8")
        fixtures.append((path, captions[filename]))
    manifest_lines = ["filename,bytes,sha256,caption"]
    for path, caption in fixtures:
        if run_dir not in path.parents and path.parent != target:
            continue
        digest = hashlib.sha256(path.read_bytes()).hexdigest()
        manifest_lines.append(
            f"{path.name},{path.stat().st_size},{digest},{caption.replace(',', ';')}"
        )
    manifest_path = run_dir / "fixture_checksum_manifest.csv"
    manifest_path.write_text("\n".join(manifest_lines) + "\n", encoding="utf-8")
    fixtures.append((manifest_path, "Fixture checksum manifest for backup audit"))
    return fixtures


def page_blueprints() -> list[Tuple[str, str, str]]:
    return [
        ("00 Lab Continuity and NICHD Mission", "Study master record and audit plan", "hypoxia/interferon developmental-stress hypothesis, synthetic approvals, roles, expected counts, checksum policy, and backup acceptance criteria"),
        ("00 Lab Continuity and NICHD Mission", "Sample accession ledger and control map", "canonical sample IDs, controls, replicates, reagent provenance, and downstream assay lineage"),
        ("00 Lab Continuity and NICHD Mission", "Program arc 1999-2026", "decades of NIH/NICHD developmental-biology continuity, lab-chief ownership, and the current preservation goal"),
        ("00 Lab Continuity and NICHD Mission", "Mission map and hypothesis board", "development, reproductive health, childhood resilience, and rehabilitation-relevant repair hypotheses"),
        ("00 Lab Continuity and NICHD Mission", "Data governance and external storage map", "non-secret repository pointers, cold archive conventions, accession placeholders, and backup boundaries"),
        ("01 Zebrafish Developmental Biology", "Embryo staging and morphometry", "zebrafish embryo staging, morphometric measurements, edema review, and light-sheet handoff"),
        ("01 Zebrafish Developmental Biology", "Larval behavior recovery assay", "5 dpf zebrafish locomotor tracking after developmental perturbation and rescue"),
        ("01 Zebrafish Developmental Biology", "Crispant line triage and imaging", "CRISPR crispant scoring, mosaic phenotype notes, confocal snapshots, and line-continuity decisions"),
        ("02 Mouse Genetics and Development", "Breeding colony snapshot", "synthetic mouse colony continuity, litter tracking, genotype calls, and non-real animal IDs"),
        ("02 Mouse Genetics and Development", "Neonatal milestone and growth assay", "postnatal growth, righting reflex, motor milestone scoring, and rehabilitation-relevant endpoints"),
        ("02 Mouse Genetics and Development", "Placenta and neonatal tissue harvest", "placental zones, brain/tissue harvest, histology slide lineage, and sample banking"),
        ("03 Reproductive and Placental Systems", "Trophoblast organoid perturbation", "organoid culture, hypoxia response, branching score, and reproductive-health framing"),
        ("03 Reproductive and Placental Systems", "Steroid and lipid LC-MS pilot", "placental metabolomics, steroid-like features, extraction controls, and Orbitrap method metadata"),
        ("03 Reproductive and Placental Systems", "Single-cell pilot intake", "cell viability, nuclei isolation, sample multiplexing, and downstream cloud-analysis handoff"),
        ("04 Chemical Biology and Small Molecules", "Developmental rescue compound screen", "chemical probe library triage, zebrafish-to-cell-system translation, and dose-response decisions"),
        ("04 Chemical Biology and Small Molecules", "Purity identity and solubility review", "LC-MS purity, NMR identity checks, precipitation flags, and safe re-test decisions"),
        ("04 Chemical Biology and Small Molecules", "Target engagement validation plan", "orthogonal target engagement with thermal shift, SPR, ITC, and rescue-readout linkage"),
        ("05 Physical Molecular Biophysics", "Protein purification and SEC-MALS", "recombinant protein purification, oligomeric-state review, and chromatography trace preservation"),
        ("05 Physical Molecular Biophysics", "SPR and ITC binding kinetics", "sensorgram fits, injection heat review, binding model notes, and fit caveats"),
        ("05 Physical Molecular Biophysics", "DLS nanoDSF stability panel", "colloidal stability, thermal shift, aggregation onset, and formulation conditions"),
        ("06 Cell Systems and Molecular Assays", "Neural progenitor perturbation", "developmental neurobiology cell model, rescue assay, and qPCR readout"),
        ("06 Cell Systems and Molecular Assays", "RNA extraction and RT-qPCR panel", "TRIzol cleanup, Nanodrop QC, cytokine and developmental marker qPCR"),
        ("06 Cell Systems and Molecular Assays", "Western blot and ELISA cross-check", "protein extraction, antibody optimization, densitometry, ELISA, and interpretation tension"),
        ("07 Omics and Computational Handoff", "Bulk RNA-seq library handoff", "sample sheet, FASTQ fixture, counts matrix, MultiQC report, and analysis notebook"),
        ("07 Omics and Computational Handoff", "Amplicon variant and genome interval review", "FASTA, VCF, BED, GFF3, GenBank, and primer inventory stress content"),
        ("07 Omics and Computational Handoff", "Notebook-to-cloud data pointers", "GEO/SRA/OSF/Zenodo-style placeholders, manifest files, and pipeline YAML records"),
        ("08 Instruments and Shared Core Exports", "Microscopy and image-analysis exports", "confocal, light-sheet, OME XML metadata, plate heatmaps, and image-gallery payloads"),
        ("08 Instruments and Shared Core Exports", "Flow cytometry and cell sorting", "compensation, gating hierarchy, FACSymphony export, and sorting decision notes"),
        ("08 Instruments and Shared Core Exports", "Mass spectrometry NMR and qPCR exports", "LC-MS, NMR, qPCR, ddPCR, and instrument method metadata in one export roundup"),
        ("09 Lab Operations QA and Preservation", "Sample accession and freezer lineage", "accession, freezer box inventory, chain of custody, and long-term sample stewardship"),
        ("09 Lab Operations QA and Preservation", "Deviation CAPA and continuity drill", "freezer alarm response, mock CAPA, instrument downtime, and sample impact statement"),
        ("09 Lab Operations QA and Preservation", "PI review and backup acceptance", "owner-only backup reminder, full-size attachment verification, and read-only viewer acceptance"),
        ("10 Archive Payload Library", "Mixed original attachment library", "attachment zoo covering molecular, animal, chemical, physical, tabular, sequence, report, and code payloads"),
        ("10 Archive Payload Library", "Image figure and histology gallery", "image-heavy payloads, mock microscopy, gels, western blot, heatmaps, and histology context"),
        ("10 Archive Payload Library", "Instrument export roundup", "instrument exports, metadata XML, LC-MS/NMR/SPR/DLS/qPCR files, and data warehouse handoff"),
    ]


def write_page_specific_fixture_files(
    target: Path,
    run_slug: str,
    blueprints: list[Tuple[str, str, str]],
) -> list[Tuple[str, str, Path, str]]:
    page_root = target / run_slug / "page_specific"
    page_root.mkdir(parents=True, exist_ok=True)
    rows: list[Tuple[str, str, Path, str]] = []
    for index, (folder, page_title, focus) in enumerate(blueprints, start=1):
        page_dir = page_root / f"page_{index:02d}"
        page_dir.mkdir(parents=True, exist_ok=True)
        if index == 1:
            filename = "study_master_record_controls_and_acceptance.tsv"
            content = (
                "field\tvalue\n"
                f"project\t{SYNTHETIC_PROJECT_ID}\n"
                "hypothesis\thypoxia/interferon developmental stress axis\n"
                "expected_page_specific_attachments\tone per page\n"
                "backup_acceptance\tall originals restored by SHA-256 and byte count\n"
            )
        elif index == 2:
            filename = "sample accession ledger excerpt.csv"
            content = (
                "sample_id,model,control_group,replicate,downstream_assay\n"
                "ZF-EMB-042,zebrafish embryo,vehicle,B1,light-sheet\n"
                "MM-PL-014,mouse placenta,hypoxia-rescue,B2,LC-MS\n"
                "PROT-001,purified protein,vehicle,T1,SPR/ITC/DLS\n"
            )
        elif index % 11 == 0:
            filename = "RAW_EXPORT.txt"
            content = f"Text-suffixed page-specific raw export for {page_title}\nFocus: {focus}\n"
        elif index % 7 == 0:
            filename = "review_notes.txt"
            content = f"Duplicate filename deliberately repeated across pages.\nPage {index}: {page_title}\nAudit note: verify restore creates safe suffixes.\n"
        elif index % 5 == 0:
            filename = f"QC EXPORT PAGE {index:02d}.CSV"
            content = "metric,value,status\nblank_control,pass,ok\npositive_control,pass,ok\nreview_flag,1,review\n"
        elif index % 3 == 0:
            filename = (
                f"very_long_page_{index:02d}_hypoxia_interferon_developmental_stress_"
                "model_systems_audit_trail_attachment_name.tsv"
            )
            content = f"page\tfolder\tfocus\n{page_title}\t{folder}\t{focus}\n"
        else:
            filename = f"page_{index:02d}_audit_packet.md"
            content = textwrap.dedent(
                f"""
                # Page {index:02d} audit packet

                Folder: {folder}
                Page: {page_title}
                Focus: {focus}
                Project: {SYNTHETIC_PROJECT_ID}
                Protocol: {SYNTHETIC_PROTOCOL_ID}
                Required controls: vehicle, positive control, blank/export control, reviewer note.
                """
            ).strip() + "\n"
        path = page_dir / filename
        path.write_text(content, encoding="utf-8")
        rows.append((folder, page_title, path, f"Page-specific audit packet for {page_title}"))
    return rows


def audit_header_html(page_title: str, focus: str, index: int, run_label: str) -> str:
    instrument = INSTRUMENT_PANEL[(index - 1) % len(INSTRUMENT_PANEL)]
    sample_ids = ", ".join(sample[0] for sample in SAMPLE_MATERIALS[index % 3 : index % 3 + 4])
    if not sample_ids:
        sample_ids = ", ".join(sample[0] for sample in SAMPLE_MATERIALS[:4])
    return textwrap.dedent(
        f"""
        <h3>Standard audit header</h3>
        <table>
          <tr><th>Field</th><th>Value</th></tr>
          <tr><td>Project</td><td>{html.escape(SYNTHETIC_PROJECT_ID)}</td></tr>
          <tr><td>Hypothesis axis</td><td>hypoxia/interferon developmental-stress response across model systems</td></tr>
          <tr><td>Synthetic protocol IDs</td><td>{html.escape(SYNTHETIC_PROTOCOL_ID)}</td></tr>
          <tr><td>PI / lab chief</td><td>{html.escape(SYNTHETIC_PI)}</td></tr>
          <tr><td>Operator</td><td>{html.escape(SYNTHETIC_OPERATOR)}</td></tr>
          <tr><td>Reviewer</td><td>Synthetic QA reviewer</td></tr>
          <tr><td>Entry created</td><td>{html.escape(run_label)}</td></tr>
          <tr><td>Page index</td><td>{index:02d}</td></tr>
          <tr><td>Sample IDs</td><td>{html.escape(sample_ids)}</td></tr>
          <tr><td>Instrument / method</td><td>{html.escape(instrument)} / method DEVSTRESS-M{index:02d}</td></tr>
          <tr><td>Raw data pointer</td><td>example.org/benchvault/nichd-model-systems-storyline/raw/page-{index:02d}</td></tr>
          <tr><td>Analysis version</td><td>{html.escape(ANALYSIS_VERSION)}</td></tr>
          <tr><td>Review status</td><td>synthetic fixture, QA review required before scientific interpretation</td></tr>
          <tr><td>Page focus</td><td>{html.escape(page_title)} - {html.escape(focus)}</td></tr>
        </table>
        """
    ).strip()


def rich_protocol_html(page_title: str, focus: str, index: int, run_label: str) -> str:
    safe_title = html.escape(page_title)
    safe_focus = html.escape(focus)
    milestone_year, milestone = PROGRAM_TIMELINE[(index - 1) % len(PROGRAM_TIMELINE)]
    instrument = INSTRUMENT_PANEL[(index - 1) % len(INSTRUMENT_PANEL)]
    rows = "\n".join(
        f"<tr><td>{html.escape(sample_id)}</td><td>{html.escape(material)}</td><td>{html.escape(context)}</td><td>{html.escape(method)}</td><td>{18 + (row * 3 + index) % 16}</td></tr>"
        for row, (sample_id, material, context, method) in enumerate(
            SAMPLE_MATERIALS,
            start=1,
        )
    )
    return textwrap.dedent(
        f"""
        <h2>{safe_title}</h2>
        {audit_header_html(page_title, focus, index, run_label)}
        <p><strong>Program story:</strong> {html.escape(LAB_STORY)}</p>
        <p><strong>NICHD connection:</strong> {html.escape(NICHD_MISSION_NOTE)}</p>
        <p><strong>Current page purpose:</strong> This generated entry stresses BenchVault with verbose, realistic lab content focused on {safe_focus}. It is organized like a long-running NIH notebook page: background, decision trail, protocol notes, sample context, instrument handoff, and preservation checks.</p>
        <h3>Continuity note</h3>
        <p><strong>{html.escape(milestone_year)}:</strong> {html.escape(milestone)}. This historical marker anchors the current test page in a believable decades-long lab record without using real study identifiers.</p>
        <h3>Protocol and decision module</h3>
        <ol>
          <li>Confirm sample identity against the manifest, animal/culture lineage, freezer box map, and chain-of-custody note before opening tubes or plates.</li>
          <li>Record model-system context: zebrafish stage, mouse postnatal day, organoid passage, cell-culture batch, or purified-protein lot.</li>
          <li>Prepare fresh working dilutions, document reagent lots using synthetic IDs, and photograph plate, gel, histology, or microscopy layouts when visual evidence matters.</li>
          <li>Acquire data on the planned instrument; today&apos;s rotating instrument anchor is <strong>{html.escape(instrument)}</strong>.</li>
          <li>Capture raw instrument exports immediately after acquisition and attach the unchanged original file to the notebook page.</li>
          <li>Write a bench interpretation and a separate reviewer-facing note so the backup contains rich text, plain text, tables, links, and comments for parser/viewer validation.</li>
          <li>Link only non-secret external storage references; do not paste passwords, signed URLs, real animal protocol numbers, or private tokens.</li>
        </ol>
        <h3>Cross-model sample table</h3>
        <table>
          <tr><th>Sample</th><th>Material</th><th>Context</th><th>Primary readout</th><th>QC score</th></tr>
          {rows}
        </table>
        """
    ).strip()


def external_links_html(index: int) -> str:
    links = [
        ("NCBI GEO placeholder", "https://www.ncbi.nlm.nih.gov/geo/query/acc.cgi?acc=GSE000000"),
        ("SRA Run Browser placeholder", "https://trace.ncbi.nlm.nih.gov/Traces/sra/?run=SRR000000"),
        ("OSF project placeholder", "https://osf.io/example-benchvault-placeholder/"),
        ("Zenodo concept placeholder", "https://zenodo.org/communities/benchvault-placeholder"),
        ("Institutional storage placeholder", "https://example.org/benchvault/storage/nichd-model-systems-storyline"),
    ]
    items = "\n".join(
        f'<li><a href="{html.escape(url)}">{html.escape(label)}</a> - recorded as non-secret test metadata link {index + offset}.</li>'
        for offset, (label, url) in enumerate(links)
    )
    return f"<h3>External data pointers</h3><ul>{items}</ul><p>These links are test fixtures for rendering and backup-indexing behavior; they are not credentialed storage links.</p>"


def observation_text(page_title: str, focus: str, index: int) -> str:
    year, milestone = PROGRAM_TIMELINE[(index - 1) % len(PROGRAM_TIMELINE)]
    instrument = INSTRUMENT_PANEL[(index * 2 - 1) % len(INSTRUMENT_PANEL)]
    return textwrap.dedent(
        f"""
        Observation block for {page_title}

        Focus: {focus}. This intentionally verbose plain-text entry mimics the kind of bench-to-analysis note that accumulates in a busy NICHD molecular biology lab. The synthetic lab has a decades-long paper-to-electronic continuity trail; today this page is tied back to the {year} milestone, "{milestone}", while using modern data streams from {instrument}.

        Scientific storyline:
        The lab's central generated hypothesis is that developmental timing, cellular stress resilience, and repair capacity can be measured across zebrafish, mouse, organoid, cell, protein, and chemical systems. The notebook is organized to feel like a real PI-owned record: model-organism observations lead to molecular assays, molecular assays nominate pathways, chemical biology probes those pathways, physical biophysics checks direct target engagement, and QA/preservation pages make the result auditable.

        Bench interpretation:
        The operator noted minor timing drift between plate preparation and acquisition, reviewed reagent labels against the inventory export, and marked synthetic samples ZF-LAR-117, MM-PL-014, ORG-DEV-008, and PROT-001 for follow-up because their control behavior differs from the rest of the generated batch. No entry contains real animal protocol IDs, patient data, or credentialed storage links.

        Quick notes:
        - Reagent cold-chain check: acceptable; no tube remained at room temperature longer than the drill threshold.
        - Model-system coverage: zebrafish embryo/larva, mouse neonatal/placental tissue, trophoblast organoid, neural progenitor culture, and purified protein are all represented as synthetic fixtures.
        - Biological replicate status: complete for controls, partial for developmental rescue arm, review needed before downstream differential analysis.
        - Chemical/physical molecular coverage: compound plate maps, LC-MS, NMR, SEC-MALS, SPR, ITC, DLS, and nanoDSF fixtures are represented in the attachment library.
        - Instrument export status: raw export attached or represented in the organized payload pages.
        - Backup stress behavior requested: preserve long text, line breaks, punctuation, sample IDs, file names, comments in the archive, and external-link context.

        Detailed reviewer narrative {index:02d}: The result is not meant to be scientifically actionable. It is intentionally dense test data that should make the read-only viewer render large pages, long words, lists, tables, comments, and many attachments without truncating meaningful context. The PI/lab-chief backup rule still applies; full-size LabArchives backups require owner credentials.
        """
    ).strip()


def qa_table_html(page_title: str, index: int) -> str:
    safe_title = html.escape(page_title)
    rows = "\n".join(
        f"<tr><td>{html.escape(metric)}</td><td>{html.escape(status)}</td><td>{html.escape(note)}</td></tr>"
        for metric, status, note in [
            ("Identity check", "pass", "sample ID matched local accession table"),
            ("Original file capture", "pass", "unchanged raw or mock file attached"),
            ("Interpretation", "review", "generated note needs human scientific review"),
            ("Storyline placement", "pass", "page fits the synthetic NICHD lab arc"),
            ("Sensitive data check", "pass", "no real animal protocol IDs, names, or credentials"),
            ("Backup relevance", "pass", f"page storyline index {index:02d}"),
        ]
    )
    return f"<h3>QA review for {safe_title}</h3><table><tr><th>Metric</th><th>Status</th><th>Note</th></tr>{rows}</table>"


def add_verbose_page(uid: str, nbid: str, pid: str, page_title: str, focus: str, index: int, run_label: str) -> int:
    entries = 0
    heading_eid = add_entry(uid, nbid, pid, "heading", page_title)
    entries += 1
    add_comment(
        uid,
        heading_eid,
        f"BenchVault NICHD storyline seed {run_label}: page {index:02d} fits the model-systems lab narrative. Comment capture is included in the LabArchives backup payload; viewer rendering support should be verified separately.",
    )
    add_entry(uid, nbid, pid, "text entry", rich_protocol_html(page_title, focus, index, run_label))
    entries += 1
    add_entry(uid, nbid, pid, "plain text entry", observation_text(page_title, focus, index))
    entries += 1
    add_entry(uid, nbid, pid, "text entry", qa_table_html(page_title, index))
    entries += 1
    add_entry(
        uid,
        nbid,
        pid,
        "plain text entry",
        f"Quick note {index:02d}: rerun if the backup or viewer fails to preserve this page title, multi-paragraph notes, attachment metadata, or original attachment payloads. Comments and link targets are intentionally present in the source archive for future parser/viewer validation.",
    )
    entries += 1
    if index % 3 == 0:
        add_entry(uid, nbid, pid, "text entry", external_links_html(index))
        entries += 1
    return entries


def main() -> int:
    args = parse_args()
    if not ensure_explicit_write_intent(args):
        return 0
    user = load_env(LOCAL / "labarchives_user.env")
    uid = user["LABARCHIVES_GOV_UID"]
    notebook_name, nbid = notebook_choice(uid, args.fresh)

    run_label = time.strftime("%Y-%m-%d %H:%M:%S")
    run_slug = time.strftime("nichd_story_%Y%m%d_%H%M%S")
    root_label = f"NICHD Model Systems Lab Storyline {run_label}"
    run_root = insert_node(uid, nbid, "0", root_label, True)

    blueprints = page_blueprints()
    total_pages = len(blueprints)
    folder_ids: Dict[str, str] = {}
    pages: Dict[str, str] = {}
    entry_count = 0

    for folder, page_title, focus in blueprints:
        if folder not in folder_ids:
            folder_ids[folder] = insert_node(uid, nbid, run_root, folder, True)
        page_path = f"{root_label}/{folder}/{page_title}"
        pid = insert_node(uid, nbid, folder_ids[folder], page_title, False)
        pages[page_path] = pid
        entry_count += add_verbose_page(uid, nbid, pid, page_title, focus, len(pages), run_label)
        print(f"Populated page {len(pages):02d}/{total_pages}.")

    payload_dir = LOCAL / "test_payloads"
    fixtures = write_large_fixture_files(payload_dir, run_slug)
    page_fixtures = write_page_specific_fixture_files(
        payload_dir,
        run_slug,
        blueprints,
    )
    model_page = pages[f"{root_label}/09 Lab Operations QA and Preservation/Sample accession and freezer lineage"]
    chemistry_page = pages[f"{root_label}/04 Chemical Biology and Small Molecules/Purity identity and solubility review"]
    payload_page = pages[f"{root_label}/10 Archive Payload Library/Mixed original attachment library"]
    image_page = pages[f"{root_label}/10 Archive Payload Library/Image figure and histology gallery"]
    instrument_page = pages[f"{root_label}/10 Archive Payload Library/Instrument export roundup"]

    add_entry(
        uid,
        nbid,
        payload_page,
        "text entry",
        f"<h2>Organized attachment library</h2><p>This run uploads {len(fixtures)} shared fixture files and {len(page_fixtures)} page-specific audit packets spanning model-organism records, molecular-biology tables, chemical and physical molecular assays, sequence formats, instrument exports, images, scripts, reports, and notebook payloads. Attachments are routed to storyline pages so backup restore tests can verify realistic destinations as well as raw payload preservation.</p>",
    )
    entry_count += 1

    attachment_count = 0
    attachment_rows: list[Tuple[str, str, str]] = []
    for folder, page_title, path, caption in page_fixtures:
        page_path = f"{root_label}/{folder}/{page_title}"
        eid = add_attachment(uid, nbid, pages[page_path], path, caption)
        attachment_count += 1
        attachment_rows.append(("page-specific", path.name, eid))
        if attachment_count % 10 == 0:
            print(
                f"Uploaded {attachment_count}/{len(fixtures) + len(page_fixtures)} attachments."
            )

    for path, caption in fixtures:
        suffix = path.suffix.lower()
        name = path.name.lower()
        if suffix in {".png", ".svg"}:
            destination = image_page
            destination_label = "image-gallery"
        elif any(
            token in name
            for token in [
                "zebrafish",
                "mouse",
                "animal",
                "organoid",
                "histology",
                "metabolomics_sample",
                "freezer",
            ]
        ):
            destination = model_page
            destination_label = "model-system-lineage"
        elif any(
            token in name
            for token in [
                "compound",
                "lc_ms",
                "nmr",
                "spr",
                "itc",
                "dls",
                "sec_mals",
                "nano_dsf",
                "biophysics",
                "mass_spec",
            ]
        ):
            destination = chemistry_page
            destination_label = "chemical-biophysics"
        elif any(
            token in name
            for token in [
                "export",
                "instrument",
                "metadata",
                "method",
                "runinfo",
                "runparameters",
                "interop",
                "qpcr",
                "flow",
                "fcs",
                "eds",
            ]
        ):
            destination = instrument_page
            destination_label = "instrument-export"
        else:
            destination = payload_page
            destination_label = "mixed-library"
        eid = add_attachment(uid, nbid, destination, path, caption)
        attachment_count += 1
        attachment_rows.append((destination_label, path.name, eid))
        if attachment_count % 10 == 0:
            print(
                f"Uploaded {attachment_count}/{len(fixtures) + len(page_fixtures)} attachments."
            )

    output = LOCAL / "benchvault_integration_notebook.tsv"
    with output.open("w", encoding="utf-8", newline="") as handle:
        writer = csv.writer(handle, delimiter="\t")
        writer.writerow(["kind", "notebook_name", "nbid", "item_path", "item_id", "run_label"])
        writer.writerow(["notebook", notebook_name, nbid, root_label, run_root, run_label])
        for page_path, pid in pages.items():
            writer.writerow(["page", notebook_name, nbid, page_path, pid, run_label])
        for destination_label, filename, eid in attachment_rows:
            writer.writerow(["attachment", notebook_name, nbid, f"{destination_label}/{filename}", eid, run_label])
    os.chmod(output, 0o600)
    refresh_notebooks(uid)
    print(
        f"Populated dedicated notebook with {len(pages)} new pages, {entry_count} text entries, {len(pages)} comments, and {attachment_count} attachments."
    )
    print("Saved local test notebook IDs.")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
