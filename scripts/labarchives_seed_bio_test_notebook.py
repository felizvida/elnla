#!/usr/bin/env python3
"""Create and populate a dedicated LabArchives notebook for ELNLA testing.

The script reads credentials and UID from local_credentials/, creates a new
notebook when needed, adds folders/pages, writes text/rich-text content,
uploads bio-lab fixture files, and saves all returned IDs locally. It
deliberately prints only high-level progress; exact IDs stay in ignored local
files.
"""

from __future__ import annotations

import argparse
import base64
import csv
import hashlib
import hmac
import html
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
import zlib


ROOT = Path(__file__).resolve().parents[1]
LOCAL = ROOT / "local_credentials"
BASE_URL = "https://api.labarchives-gov.com"
API_PAUSE_SECONDS = 1.05


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
    return read_response(req, timeout=60)


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
    return read_response(req, timeout=60)


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


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(
        description="Populate the local ELNLA LabArchives integration notebook with a large molecular-biology stress dataset."
    )
    parser.add_argument(
        "--fresh",
        action="store_true",
        help="Create a new integration notebook instead of reusing the latest local one.",
    )
    return parser.parse_args()


def load_existing_integration_notebook() -> Tuple[str, str] | None:
    output = LOCAL / "elnla_integration_notebook.tsv"
    if not output.exists():
        return None
    with output.open("r", encoding="utf-8", newline="") as handle:
        reader = csv.DictReader(handle, delimiter="\t")
        for row in reader:
            name = row.get("notebook_name", "").strip()
            nbid = row.get("nbid", "").strip()
            if name and nbid:
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
            if name.startswith("ELNLA Integration Test")
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

    extra: Dict[str, str | bytes] = {
        "rna_seq_counts_matrix.tsv": "\n".join(gene_rows) + "\n",
        "qpcr_raw_export_384well.csv": "\n".join(qpcr_rows) + "\n",
        "flow_events_subset.csv": "\n".join(flow_rows) + "\n",
        "freezer_box_inventory.csv": "\n".join(freezer_rows) + "\n",
        "western_blot_densitometry.csv": "lane,target,background_corrected_intensity,normalized_to_actb\n1,STAT1,18333,0.91\n2,pSTAT1,24119,1.38\n3,ACTB,19811,1.00\n",
        "illumina_sample_sheet.csv": "[Header],,,,,\nIEMFileVersion,5,,,,\n[Data],,,,,\nSample_ID,Sample_Name,index,index2,Description,Project\nS001,PBMC_control,ATCACG,CGATGT,control,ELNLA\nS002,PBMC_LPS4h,CGATGT,TGACCA,treated,ELNLA\n",
        "primer_inventory.csv": "primer_id,target,sequence,tm_c,storage_box\nP001,IL6_F,ACTCACCTCTTCAGAACGAATTG,60.1,BOX-1\nP002,IL6_R,CCATCTTTGGAAGGTTCAGGTTG,60.4,BOX-1\n",
        "crispr_guides.tsv": "guide_id\tgene\tsequence\tpam\toff_target_review\nG001\tSTAT1\tGAGTACATGCTGACCCACAA\tGGG\tpass\nG002\tIRF1\tTCCACCTCTCACCAAGATCC\tAGG\treview_required\n",
        "elisa_plate_readout.csv": "well,standard_pg_ml,od450,od570_corrected\nA01,1000,2.110,2.010\nA02,500,1.532,1.432\nB01,,0.771,0.690\n",
        "nanodrop_export.csv": "sample,ng_ul,260_280,260_230,comment\nRNA_S001,512.4,2.05,2.21,excellent\nRNA_S002,288.1,1.97,1.83,cleanup optional\n",
        "cell_counter_export.csv": "sample,total_cells,viability_percent,dilution\nPBMC_S001,1480000,96.2,2\nPBMC_S002,1315000,91.8,2\n",
        "fastq_tiny_lane001.fastq": "@SEQ_ID_1\nGATTTGGGGTTCAAAGCAGTATCGATCAAATAGTAAAT\n+\nIIIIIIIIIIIIIIIIIIIIIIIIIIIIIIIIIIIIII\n@SEQ_ID_2\nCTGATCGTAGCTAGCTAGGATCGATCGATCGATCGAA\n+\nIIIIIIIIIIIIIIIIIIIIIIIIIIIIIIIIIIIII\n",
        "reference_transcript.fa": ">NM_ELNLA_TEST cytokine response transcript\nATGGCTGCTGCTGAACTGACCTTGACCGAGGAGGACCTGAGCTTCCAGGACATG\n",
        "gene_models.gff3": "##gff-version 3\nchrTest\tELNLA\tgene\t100\t950\t.\t+\t.\tID=gene0001;Name=ELNLA1\nchrTest\tELNLA\texon\t100\t220\t.\t+\t.\tParent=gene0001\n",
        "construct_map.gb": "LOCUS       ELNLA_STRESS    620 bp    DNA     circular SYN 14-MAY-2026\nFEATURES             Location/Qualifiers\n     promoter        1..100\n     misc_feature    101..160\n     CDS             161..520\nORIGIN\n        1 atggccattgtaatgggccgctgaaagggtgcccgacgaacgttactgacgactgacgac\n//\n",
        "analysis_manifest.json": json.dumps(
            {
                "run": run_slug,
                "pipelines": ["fastqc", "multiqc", "salmon", "deseq2", "custom-qc"],
                "expected_files": 51,
                "storage": {
                    "primary": "example.org/project-storage/elnla/stress-run",
                    "cold_archive": "s3://example-elnla-cold-archive/stress-run",
                },
            },
            indent=2,
        ),
        "lims_export.json": json.dumps(
            {
                "samples": [
                    {"sample_id": "S001", "matrix": "PBMC", "consent": "not_applicable_test_fixture"},
                    {"sample_id": "S002", "matrix": "PBMC", "consent": "not_applicable_test_fixture"},
                ],
                "chain_of_custody": ["received", "accessioned", "extracted", "sequenced"],
            },
            indent=2,
        ),
        "cloud_storage_manifest.json": json.dumps(
            {
                "links": [
                    "https://example.org/elnla/stress-run/raw",
                    "https://osf.io/example-elnla-placeholder/",
                    "https://www.ncbi.nlm.nih.gov/geo/query/acc.cgi?acc=GSE000000",
                    "globus://example-endpoint/elnla/stress-run",
                ]
            },
            indent=2,
        ),
        "qc_flags.json": json.dumps(
            {"flags": ["low RNA yield S002", "review melt curve B17", "rerun flow compensation if PE spillover persists"]},
            indent=2,
        ),
        "instrument_metadata.xml": "<instrument><name>QuantStudio 7 Flex</name><plate>384</plate><operator>ELNLA seed</operator><runMode>test-fixture</runMode></instrument>\n",
        "microscope_metadata.ome.xml": "<OME><Image ID=\"Image:0\"><Pixels DimensionOrder=\"XYZCT\" Type=\"uint16\" SizeX=\"1024\" SizeY=\"1024\" SizeZ=\"1\" SizeC=\"3\" SizeT=\"1\"/></Image></OME>\n",
        "master_protocol.md": "# Master molecular biology protocol\n\n## Modules\n\n1. Cell thaw and rest\n2. LPS stimulation\n3. RNA extraction\n4. Library prep\n5. Bioinformatics handoff\n\nAll steps are generated test content for ELNLA backup verification.\n",
        "capa_record.md": "# CAPA drill\n\nDeviation: temperature excursion alarm acknowledged late.\n\nCorrective action: document transfer to backup freezer, review logger export, annotate sample impact as no biological material affected in this test fixture.\n",
        "rna_seq_multiqc_report.html": "<html><body><h1>Mock MultiQC report</h1><p>All modules pass except adapter content review for S002.</p><ul><li>FastQC: pass</li><li>Salmon mapping: pass</li><li>Duplication: warning</li></ul></body></html>\n",
        "analysis_notebook.ipynb": json.dumps(
            {
                "cells": [
                    {"cell_type": "markdown", "metadata": {}, "source": ["# ELNLA stress analysis\n", "Large notebook fixture.\n"]},
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
        "warehouse_queries.sql": "select sample_id, freezer_box, position from aliquots where project = 'ELNLA_STRESS';\n",
        "workflow.yaml": "name: elnla-stress-fixture\nsteps:\n  - fastqc\n  - multiqc\n  - salmon\n  - deseq2\n",
        "plate_heatmap.png": plate_heatmap_png(),
        "mock_microscopy.png": microscopy_png(),
        "flow_gate_density.png": flow_density_png(),
        "western_blot_mock.svg": "<svg xmlns=\"http://www.w3.org/2000/svg\" width=\"420\" height=\"220\"><rect width=\"420\" height=\"220\" fill=\"#f7faf7\"/><rect x=\"45\" y=\"30\" width=\"36\" height=\"150\" fill=\"#111\"/><rect x=\"115\" y=\"70\" width=\"36\" height=\"90\" fill=\"#333\"/><rect x=\"185\" y=\"45\" width=\"36\" height=\"135\" fill=\"#111\"/><rect x=\"255\" y=\"95\" width=\"36\" height=\"62\" fill=\"#555\"/><text x=\"30\" y=\"205\" font-family=\"Arial\" font-size=\"18\">Mock western blot lanes</text></svg>\n",
        "gel_ladder_detailed.svg": "<svg xmlns=\"http://www.w3.org/2000/svg\" width=\"420\" height=\"220\"><rect width=\"420\" height=\"220\" fill=\"#101820\"/><g fill=\"#86efac\"><rect x=\"60\" y=\"35\" width=\"34\" height=\"8\"/><rect x=\"60\" y=\"60\" width=\"34\" height=\"8\"/><rect x=\"60\" y=\"92\" width=\"34\" height=\"8\"/><rect x=\"140\" y=\"70\" width=\"34\" height=\"8\"/><rect x=\"220\" y=\"55\" width=\"34\" height=\"8\"/><rect x=\"300\" y=\"105\" width=\"34\" height=\"8\"/></g><text x=\"25\" y=\"200\" fill=\"white\" font-family=\"Arial\" font-size=\"18\">Mock agarose gel with ladder</text></svg>\n",
        "long_protocol_summary.pdf": minimal_pdf("ELNLA large protocol summary"),
        "sample_chain_of_custody.pdf": minimal_pdf("ELNLA sample chain of custody"),
    }
    captions = {
        "rna_seq_counts_matrix.tsv": "Large RNA-seq counts matrix",
        "qpcr_raw_export_384well.csv": "384-well qPCR raw export",
        "flow_events_subset.csv": "Flow cytometry event subset",
        "freezer_box_inventory.csv": "Freezer box inventory export",
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
        "master_protocol.md": "Master protocol Markdown",
        "capa_record.md": "CAPA drill Markdown",
        "rna_seq_multiqc_report.html": "Mock MultiQC HTML report",
        "analysis_notebook.ipynb": "Analysis notebook payload",
        "analysis_script.py": "Python helper script",
        "normalization.R": "R normalization script",
        "warehouse_queries.sql": "Warehouse query SQL",
        "workflow.yaml": "Workflow YAML",
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
    return fixtures


def page_blueprints() -> list[Tuple[str, str, str]]:
    return [
        ("00 Study Overview", "Program brief and external storage map", "cross-team study design, storage handoff, accession tracking"),
        ("00 Study Overview", "Daily triage quick notes", "short operational notes, handoff risks, and next-day reminders"),
        ("00 Study Overview", "Sample accession and chain of custody", "sample intake, aliquot lineage, freezer mapping, custody review"),
        ("01 Molecular Cloning", "Gibson assembly design", "fragment design, overlap review, construct naming, assembly controls"),
        ("01 Molecular Cloning", "Colony PCR and miniprep QC", "clone screening, gel review, miniprep concentration checks"),
        ("01 Molecular Cloning", "Sanger sequencing review", "trace review, variant confirmation, primer coverage gaps"),
        ("02 Cell Culture", "Seeding transfection and perturbation", "cell culture plate setup, transfection controls, perturbation plan"),
        ("02 Cell Culture", "Drug treatment time course", "dose response, time-course sampling, media change notes"),
        ("02 Cell Culture", "Mycoplasma response drill", "contamination drill, quarantine notes, mock CAPA workflow"),
        ("03 Nucleic Acid Assays", "RNA extraction batch log", "TRIzol column cleanup, extraction batches, RNA QC"),
        ("03 Nucleic Acid Assays", "RT-qPCR cytokine panel", "cytokine panel qPCR, plate controls, melt-curve review"),
        ("03 Nucleic Acid Assays", "ddPCR copy number pilot", "droplet counts, copy-number pilot design, threshold review"),
        ("04 Sequencing Bioinformatics", "Bulk RNA-seq handoff", "library prep, sample sheet, QC transfer, pipeline trigger"),
        ("04 Sequencing Bioinformatics", "Amplicon variant review", "amplicon sequencing, VCF review, BED target intervals"),
        ("04 Sequencing Bioinformatics", "Notebook-to-cloud data pointers", "external storage links, DOI placeholders, archive staging"),
        ("05 Protein Imaging Cytometry", "Western blot optimization", "protein extraction, antibody titration, densitometry"),
        ("05 Protein Imaging Cytometry", "Immunofluorescence microscopy", "microscopy acquisition, channel setup, image annotations"),
        ("05 Protein Imaging Cytometry", "Flow cytometry gating notes", "compensation, gating hierarchy, event export review"),
        ("06 Compliance QA", "Deviation CAPA record", "quality event drill, corrective action, review notes"),
        ("06 Compliance QA", "Read-only backup acceptance", "viewer acceptance, original attachment verification, audit expectations"),
        ("06 Compliance QA", "PI review checklist", "owner-only backup reminder, PI/lab-chief review, final signoff"),
        ("07 Attachment Stress", "Large mixed payload library", "attachment zoo covering text, tabular, sequence, binary, image, and report formats"),
        ("07 Attachment Stress", "Image and figure gallery", "image-heavy payloads, mock microscopy, gel, western blot, heatmaps"),
        ("07 Attachment Stress", "Instrument export roundup", "instrument exports, metadata XML, data warehouse handoff"),
    ]


def rich_protocol_html(page_title: str, focus: str, index: int) -> str:
    safe_title = html.escape(page_title)
    safe_focus = html.escape(focus)
    rows = "\n".join(
        f"<tr><td>S{sample:03d}</td><td>{html.escape(['PBMC', 'HEK293T', 'K562', 'THP-1'][sample % 4])}</td><td>{html.escape(['control', 'LPS 4h', 'IFN beta', 'rescue'][sample % 4])}</td><td>{18 + (sample * 3 + index) % 16}</td></tr>"
        for sample in range(1, 9)
    )
    return textwrap.dedent(
        f"""
        <h2>{safe_title}</h2>
        <p><strong>Purpose:</strong> This generated page stresses ELNLA with verbose molecular-biology content focused on {safe_focus}. The text intentionally mixes protocol detail, operational handoff language, tables, external references, and backup-relevant edge cases.</p>
        <h3>Protocol module</h3>
        <ol>
          <li>Confirm sample identity against the manifest, freezer box map, and chain-of-custody note before opening tubes.</li>
          <li>Prepare fresh working dilutions, record reagent lot numbers, and photograph plate or gel layouts when visual evidence matters.</li>
          <li>Capture raw instrument exports immediately after acquisition and attach the unchanged original file to the notebook page.</li>
          <li>Write a short interpretation and a separate reviewer-facing note so the read-only backup viewer has rich and plain-text material to render.</li>
          <li>Link external storage locations using non-secret references; do not paste passwords, signed URLs, or private tokens.</li>
        </ol>
        <h3>Sample table</h3>
        <table>
          <tr><th>Sample</th><th>Material</th><th>Treatment</th><th>QC score</th></tr>
          {rows}
        </table>
        """
    ).strip()


def external_links_html(index: int) -> str:
    links = [
        ("NCBI GEO placeholder", "https://www.ncbi.nlm.nih.gov/geo/query/acc.cgi?acc=GSE000000"),
        ("SRA Run Browser placeholder", "https://trace.ncbi.nlm.nih.gov/Traces/sra/?run=SRR000000"),
        ("OSF project placeholder", "https://osf.io/example-elnla-placeholder/"),
        ("Zenodo concept placeholder", "https://zenodo.org/communities/elnla-placeholder"),
        ("Institutional storage placeholder", "https://example.org/elnla/storage/molecular-biology-stress-run"),
    ]
    items = "\n".join(
        f'<li><a href="{html.escape(url)}">{html.escape(label)}</a> - recorded as non-secret test metadata link {index + offset}.</li>'
        for offset, (label, url) in enumerate(links)
    )
    return f"<h3>External data pointers</h3><ul>{items}</ul><p>These links are test fixtures for rendering and backup-indexing behavior; they are not credentialed storage links.</p>"


def observation_text(page_title: str, focus: str, index: int) -> str:
    return textwrap.dedent(
        f"""
        Observation block for {page_title}

        Focus: {focus}. This intentionally verbose plain-text entry mimics the kind of bench-to-analysis note that accumulates in a busy molecular biology web lab. The operator noted minor timing drift between plate preparation and acquisition, reviewed reagent labels against the inventory export, and marked samples S002 and S007 for follow-up because their control behavior differs from the rest of the batch.

        Quick notes:
        - Reagent cold-chain check: acceptable; no tube remained at room temperature longer than the drill threshold.
        - Biological replicate status: complete for controls, partial for rescue arm, review needed before downstream differential analysis.
        - Instrument export status: raw export attached or represented in the mixed payload library.
        - Backup stress behavior requested: preserve long text, line breaks, punctuation, sample IDs, file names, and external-link context.

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
            ("Backup relevance", "pass", f"page stress index {index:02d}"),
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
        f"ELNLA stress seed {run_label}: page {index:02d} includes rich text, plain text, tables, links, and backup-viewer edge cases.",
    )
    add_entry(uid, nbid, pid, "text entry", rich_protocol_html(page_title, focus, index))
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
        f"Quick note {index:02d}: rerun if the viewer fails to preserve this page title, comments, multi-paragraph notes, or attachment references. Attachments for this run are distributed across the stress attachment pages.",
    )
    entries += 1
    if index % 3 == 0:
        add_entry(uid, nbid, pid, "text entry", external_links_html(index))
        entries += 1
    return entries


def main() -> int:
    args = parse_args()
    user = load_env(LOCAL / "labarchives_user.env")
    uid = user["LABARCHIVES_GOV_UID"]
    notebook_name, nbid = notebook_choice(uid, args.fresh)

    run_label = time.strftime("%Y-%m-%d %H:%M:%S")
    run_slug = time.strftime("stress_%Y%m%d_%H%M%S")
    root_label = f"Molecular Biology Web Lab Stress Test {run_label}"
    run_root = insert_node(uid, nbid, "0", root_label, True)

    blueprints = page_blueprints()
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
        print(f"Populated page {len(pages):02d}/24.")

    payload_dir = LOCAL / "test_payloads"
    fixtures = write_large_fixture_files(payload_dir, run_slug)
    payload_page = pages[f"{root_label}/07 Attachment Stress/Large mixed payload library"]
    image_page = pages[f"{root_label}/07 Attachment Stress/Image and figure gallery"]
    instrument_page = pages[f"{root_label}/07 Attachment Stress/Instrument export roundup"]

    add_entry(
        uid,
        nbid,
        payload_page,
        "text entry",
        f"<h2>Attachment library</h2><p>This run uploads {len(fixtures)} fixture files spanning molecular-biology tables, sequence formats, instrument exports, images, scripts, reports, and notebook payloads.</p>",
    )
    entry_count += 1

    attachment_count = 0
    attachment_rows: list[Tuple[str, str, str]] = []
    for path, caption in fixtures:
        suffix = path.suffix.lower()
        if suffix in {".png", ".svg"}:
            destination = image_page
            destination_label = "image-gallery"
        elif suffix in {".csv", ".xml"} and any(token in path.name for token in ["export", "instrument", "metadata"]):
            destination = instrument_page
            destination_label = "instrument-export"
        else:
            destination = payload_page
            destination_label = "mixed-library"
        eid = add_attachment(uid, nbid, destination, path, caption)
        attachment_count += 1
        attachment_rows.append((destination_label, path.name, eid))
        if attachment_count % 10 == 0:
            print(f"Uploaded {attachment_count}/{len(fixtures)} attachments.")

    output = LOCAL / "elnla_integration_notebook.tsv"
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
