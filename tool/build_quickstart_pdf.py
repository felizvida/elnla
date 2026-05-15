#!/usr/bin/env python3
"""Build the BenchVault quickstart PDF from docs/user/quickstart.md."""

from __future__ import annotations

import re
from pathlib import Path
from xml.sax.saxutils import escape

from reportlab.lib import colors
from reportlab.lib.enums import TA_CENTER, TA_RIGHT
from reportlab.lib.pagesizes import letter
from reportlab.lib.styles import ParagraphStyle, getSampleStyleSheet
from reportlab.lib.units import inch
from reportlab.lib.utils import ImageReader
from reportlab.platypus import (
    CondPageBreak,
    Image,
    KeepTogether,
    ListFlowable,
    ListItem,
    PageBreak,
    Paragraph,
    Preformatted,
    SimpleDocTemplate,
    Spacer,
    Table,
    TableStyle,
)
from reportlab.platypus.flowables import HRFlowable


ROOT = Path(__file__).resolve().parents[1]
SOURCE = ROOT / "docs/user/quickstart.md"
OUTPUT = ROOT / "docs/user/BenchVault_Quickstart.pdf"

PAGE_WIDTH, PAGE_HEIGHT = letter
MARGIN_X = 0.62 * inch
CONTENT_WIDTH = PAGE_WIDTH - 2 * MARGIN_X

NIH_BLUE = colors.HexColor("#005ea2")
NIH_BLUE_DARK = colors.HexColor("#162e51")
NIH_BLUE_PALE = colors.HexColor("#eef7fb")
NIH_GOLD = colors.HexColor("#face00")
NIH_GOLD_PALE = colors.HexColor("#fff8d8")
INK = colors.HexColor("#1f2933")
MUTED = colors.HexColor("#5f6f7a")
RULE = colors.HexColor("#c8d2dc")
PAPER = colors.HexColor("#fbfcfd")
SECTION_PAGE_BREAKS = {
    "First Launch Setup",
    "Backup Folder Structure",
}


def styles() -> dict[str, ParagraphStyle]:
    base = getSampleStyleSheet()
    return {
        "cover_eyebrow": ParagraphStyle(
            name="CoverEyebrow",
            parent=base["BodyText"],
            alignment=TA_CENTER,
            fontName="Helvetica-Bold",
            fontSize=8,
            leading=10,
            textColor=NIH_BLUE,
            uppercase=True,
            spaceAfter=7,
        ),
        "cover_title": ParagraphStyle(
            name="CoverTitle",
            parent=base["Title"],
            alignment=TA_CENTER,
            fontName="Helvetica-Bold",
            fontSize=31,
            leading=35,
            textColor=NIH_BLUE_DARK,
            spaceAfter=7,
        ),
        "cover_subtitle": ParagraphStyle(
            name="CoverSubtitle",
            parent=base["BodyText"],
            alignment=TA_CENTER,
            fontName="Helvetica",
            fontSize=13,
            leading=17,
            textColor=INK,
            spaceAfter=12,
        ),
        "cover_meta": ParagraphStyle(
            name="CoverMeta",
            parent=base["BodyText"],
            alignment=TA_CENTER,
            fontName="Helvetica",
            fontSize=8.8,
            leading=11,
            textColor=MUTED,
        ),
        "chip": ParagraphStyle(
            name="CoverChip",
            parent=base["BodyText"],
            alignment=TA_CENTER,
            fontName="Helvetica-Bold",
            fontSize=8.4,
            leading=10.5,
            textColor=NIH_BLUE_DARK,
        ),
        "title": ParagraphStyle(
            name="TitlePrint",
            parent=base["Title"],
            fontName="Helvetica-Bold",
            fontSize=22,
            leading=27,
            textColor=NIH_BLUE_DARK,
            spaceAfter=10,
        ),
        "h1": ParagraphStyle(
            name="H1Print",
            parent=base["Heading1"],
            fontName="Helvetica-Bold",
            fontSize=15.5,
            leading=19,
            textColor=NIH_BLUE,
            spaceBefore=12,
            spaceAfter=8,
        ),
        "h2": ParagraphStyle(
            name="H2Print",
            parent=base["Heading2"],
            fontName="Helvetica-Bold",
            fontSize=12.5,
            leading=15.5,
            textColor=NIH_BLUE_DARK,
            spaceBefore=10,
            spaceAfter=6,
        ),
        "body": ParagraphStyle(
            name="BodyPrint",
            parent=base["BodyText"],
            fontName="Helvetica",
            fontSize=9.6,
            leading=13.1,
            textColor=INK,
            spaceAfter=5.4,
        ),
        "bullet": ParagraphStyle(
            name="BulletPrint",
            parent=base["BodyText"],
            fontName="Helvetica",
            fontSize=9.3,
            leading=12.5,
            textColor=INK,
            leftIndent=8,
            firstLineIndent=0,
            spaceAfter=2.2,
        ),
        "code": ParagraphStyle(
            name="CodePrint",
            parent=base["Code"],
            fontName="Courier",
            fontSize=7.9,
            leading=9.6,
            backColor=colors.HexColor("#f4f6f8"),
            borderColor=RULE,
            borderWidth=0.5,
            borderPadding=5,
            spaceBefore=4,
            spaceAfter=8,
        ),
        "caption": ParagraphStyle(
            name="CaptionPrint",
            parent=base["BodyText"],
            alignment=TA_CENTER,
            fontName="Helvetica-Oblique",
            fontSize=7.8,
            leading=10,
            textColor=MUTED,
            spaceBefore=3,
            spaceAfter=9,
        ),
        "callout": ParagraphStyle(
            name="CalloutPrint",
            parent=base["BodyText"],
            fontName="Helvetica",
            fontSize=8.9,
            leading=12,
            textColor=INK,
        ),
        "footer": ParagraphStyle(
            name="FooterPrint",
            parent=base["BodyText"],
            alignment=TA_RIGHT,
            fontName="Helvetica",
            fontSize=7,
            leading=8,
            textColor=MUTED,
        ),
    }


def inline_markdown(value: str) -> str:
    text = escape(value)
    text = re.sub(r"`([^`]+)`", r'<font face="Courier">\1</font>', text)
    text = re.sub(r"\*\*([^*]+)\*\*", r"<b>\1</b>", text)
    text = re.sub(r"(?<!\*)\*([^*]+)\*(?!\*)", r"<i>\1</i>", text)
    return text


def read_source() -> tuple[dict[str, str], list[str]]:
    lines = SOURCE.read_text(encoding="utf-8").splitlines()
    metadata: dict[str, str] = {}
    if lines and lines[0].strip() == "---":
        for index, line in enumerate(lines[1:], start=1):
            if line.strip() == "---":
                lines = lines[index + 1 :]
                break
            if ":" in line:
                key, value = line.split(":", 1)
                metadata[key.strip()] = value.strip().strip('"')
    return metadata, lines


def resolved_image_path(path_text: str) -> Path | None:
    clean = path_text.split("{", 1)[0].strip()
    image_path = (SOURCE.parent / clean).resolve()
    if not image_path.exists():
        image_path = (ROOT / clean).resolve()
    if not image_path.exists():
        return None
    return image_path


def image_card_flowables(
    path_text: str,
    alt_text: str,
    *,
    max_height: float = 2.28 * inch,
    caption: bool = True,
) -> list:
    image_path = resolved_image_path(path_text)
    if image_path is None:
        return []
    reader = ImageReader(str(image_path))
    width, height = reader.getSize()
    max_width = CONTENT_WIDTH - 0.28 * inch
    scale = min(max_width / width, max_height / height, 1)
    image = Image(str(image_path), width=width * scale, height=height * scale)
    image.hAlign = "CENTER"
    table = Table([[image]], colWidths=[image.drawWidth + 0.14 * inch])
    table.hAlign = "CENTER"
    table.setStyle(
        TableStyle(
            [
                ("BACKGROUND", (0, 0), (-1, -1), colors.white),
                ("BOX", (0, 0), (-1, -1), 0.6, RULE),
                ("INNERPADDING", (0, 0), (-1, -1), 0),
                ("LEFTPADDING", (0, 0), (-1, -1), 5),
                ("RIGHTPADDING", (0, 0), (-1, -1), 5),
                ("TOPPADDING", (0, 0), (-1, -1), 5),
                ("BOTTOMPADDING", (0, 0), (-1, -1), 5),
            ]
        )
    )
    flowables: list = [table]
    if caption and alt_text:
        flowables.append(
            Paragraph(f"Figure. {inline_markdown(alt_text)}.", styles()["caption"])
        )
    else:
        flowables.append(Spacer(1, 8))
    return flowables


def callout_flowable(text: str, st: dict[str, ParagraphStyle]):
    lower = text.lower()
    if "owner-only" in lower or "pi" in lower or "lab chief" in lower:
        label = "Owner-only backup rule"
        background = NIH_BLUE_PALE
        accent = NIH_BLUE
        label_color = accent
    elif "tamper" in lower or "checksum" in lower or "integrity" in lower:
        label = "Integrity note"
        background = colors.HexColor("#f3fbf9")
        accent = colors.HexColor("#0f6460")
        label_color = accent
    else:
        label = "Local handling note"
        background = NIH_GOLD_PALE
        accent = NIH_GOLD
        label_color = colors.HexColor("#6f5600")
    body = Paragraph(
        f'<font color="{label_color.hexval()}"><b>{label}</b></font><br/>'
        f"{inline_markdown(text)}",
        st["callout"],
    )
    table = Table([[body]], colWidths=[CONTENT_WIDTH])
    table.setStyle(
        TableStyle(
            [
                ("BACKGROUND", (0, 0), (-1, -1), background),
                ("BOX", (0, 0), (-1, -1), 0.45, colors.HexColor("#d6e4ee")),
                ("LINEBEFORE", (0, 0), (0, -1), 3, accent),
                ("LEFTPADDING", (0, 0), (-1, -1), 9),
                ("RIGHTPADDING", (0, 0), (-1, -1), 9),
                ("TOPPADDING", (0, 0), (-1, -1), 7),
                ("BOTTOMPADDING", (0, 0), (-1, -1), 7),
            ]
        )
    )
    return KeepTogether([Spacer(1, 3), table, Spacer(1, 7)])


def cover_story(metadata: dict[str, str], st: dict[str, ParagraphStyle]) -> list:
    subtitle = metadata.get(
        "subtitle", "Back up LabArchives GOV notebooks and read them offline"
    )
    date = metadata.get("date", "May 15, 2026")
    chips = [
        Paragraph("Full-size archives", st["chip"]),
        Paragraph("Read-only viewer", st["chip"]),
        Paragraph("Integrity warnings", st["chip"]),
    ]
    chip_table = Table([chips], colWidths=[CONTENT_WIDTH / 3] * 3)
    chip_table.setStyle(
        TableStyle(
            [
                ("BACKGROUND", (0, 0), (-1, -1), NIH_BLUE_PALE),
                ("BOX", (0, 0), (-1, -1), 0.4, RULE),
                ("INNERGRID", (0, 0), (-1, -1), 0.35, colors.white),
                ("LEFTPADDING", (0, 0), (-1, -1), 7),
                ("RIGHTPADDING", (0, 0), (-1, -1), 7),
                ("TOPPADDING", (0, 0), (-1, -1), 7),
                ("BOTTOMPADDING", (0, 0), (-1, -1), 7),
            ]
        )
    )
    cover_note = callout_flowable(
        "At NIH and NICHD, full-size LabArchives notebook backup is owner-only. "
        "BenchVault helps make that permission boundary visible before someone "
        "mistakes a policy restriction for a software failure.",
        st,
    )
    flowables = [
        Spacer(1, 0.14 * inch),
        Paragraph("BENCHVAULT QUICKSTART", st["cover_eyebrow"]),
        Paragraph("Back up lab notebooks. Read them calmly later.", st["cover_title"]),
        Paragraph(inline_markdown(subtitle), st["cover_subtitle"]),
        HRFlowable(width=1.25 * inch, thickness=1.2, color=NIH_GOLD, hAlign="CENTER"),
        Spacer(1, 0.17 * inch),
        chip_table,
        Spacer(1, 0.18 * inch),
        cover_note,
        Spacer(1, 0.08 * inch),
        *image_card_flowables(
            "../assets/screenshots/benchvault-viewer.png",
            "",
            max_height=2.25 * inch,
            caption=False,
        ),
        Spacer(1, 0.08 * inch),
        Paragraph(
            f"{date} · macOS first · Windows and iPad path scaffolded",
            st["cover_meta"],
        ),
        PageBreak(),
    ]
    return flowables


def append_paragraph(story: list, paragraph: list[str], style: ParagraphStyle) -> None:
    text = " ".join(line.strip() for line in paragraph if line.strip())
    if text:
        story.append(Paragraph(inline_markdown(text), style))
    paragraph.clear()


def build_story() -> list:
    st = styles()
    metadata, lines = read_source()
    story: list = cover_story(metadata, st)
    paragraph: list[str] = []
    bullets: list[str] = []
    numbers: list[str] = []
    quotes: list[str] = []
    code: list[str] = []
    in_code = False
    skipped_cover_title = False
    skipped_cover_image = False

    def flush_lists() -> None:
        nonlocal bullets, numbers
        if bullets:
            story.append(
                ListFlowable(
                    [
                        ListItem(Paragraph(inline_markdown(item), st["bullet"]))
                        for item in bullets
                    ],
                    bulletType="bullet",
                    leftIndent=16,
                )
            )
            bullets = []
        if numbers:
            story.append(
                ListFlowable(
                    [
                        ListItem(Paragraph(inline_markdown(item), st["bullet"]))
                        for item in numbers
                    ],
                    bulletType="1",
                    leftIndent=18,
                )
            )
            numbers = []

    def flush_quotes() -> None:
        nonlocal quotes
        if quotes:
            story.append(callout_flowable(" ".join(quotes), st))
            quotes = []

    for line in lines:
        raw = line.rstrip()
        if raw.startswith("```"):
            if in_code:
                story.append(Preformatted("\n".join(code), st["code"]))
                code = []
                in_code = False
            else:
                append_paragraph(story, paragraph, st["body"])
                flush_lists()
                flush_quotes()
                in_code = True
                code = []
            continue
        if in_code:
            code.append(raw)
            continue

        if raw.startswith("> "):
            append_paragraph(story, paragraph, st["body"])
            flush_lists()
            quotes.append(raw[2:].strip())
            continue

        image_match = re.match(r"!\[([^]]*)]\(([^)]+)\)", raw)
        if image_match:
            append_paragraph(story, paragraph, st["body"])
            flush_lists()
            flush_quotes()
            if not skipped_cover_image:
                skipped_cover_image = True
                continue
            story.extend(
                image_card_flowables(image_match.group(2), image_match.group(1))
            )
            continue

        if raw.startswith("# "):
            append_paragraph(story, paragraph, st["body"])
            flush_lists()
            flush_quotes()
            if not skipped_cover_title:
                skipped_cover_title = True
                continue
            story.append(Paragraph(inline_markdown(raw[2:]), st["title"]))
            continue
        if raw.startswith("## "):
            append_paragraph(story, paragraph, st["body"])
            flush_lists()
            flush_quotes()
            heading = raw[3:]
            if heading in SECTION_PAGE_BREAKS:
                story.append(CondPageBreak(2.1 * inch))
            story.extend(
                [
                    Spacer(1, 2),
                    HRFlowable(width=0.55 * inch, thickness=1, color=NIH_GOLD),
                    Paragraph(inline_markdown(heading), st["h1"]),
                ]
            )
            continue
        if raw.startswith("### "):
            append_paragraph(story, paragraph, st["body"])
            flush_lists()
            flush_quotes()
            story.append(Paragraph(inline_markdown(raw[4:]), st["h2"]))
            continue
        if raw.startswith("- "):
            append_paragraph(story, paragraph, st["body"])
            flush_quotes()
            numbers = []
            bullets.append(raw[2:])
            continue
        if bullets and raw.startswith("  ") and raw.strip():
            bullets[-1] = f"{bullets[-1]} {raw.strip()}"
            continue
        numbered = re.match(r"\d+\.\s+(.*)", raw)
        if numbered:
            append_paragraph(story, paragraph, st["body"])
            flush_quotes()
            bullets = []
            numbers.append(numbered.group(1))
            continue
        if numbers and raw.startswith("  ") and raw.strip():
            numbers[-1] = f"{numbers[-1]} {raw.strip()}"
            continue
        if not raw.strip():
            append_paragraph(story, paragraph, st["body"])
            flush_lists()
            flush_quotes()
            story.append(Spacer(1, 3))
            continue
        paragraph.append(raw)

    append_paragraph(story, paragraph, st["body"])
    flush_lists()
    flush_quotes()
    return story


def draw_first_page(canvas, doc) -> None:
    canvas.setTitle("BenchVault Quickstart")
    canvas.setAuthor("BenchVault")
    canvas.setSubject("LabArchives GOV backup and read-only viewer quickstart")
    canvas.setKeywords(
        "BenchVault, LabArchives GOV, electronic lab notebook, backup, read-only viewer"
    )
    canvas.setCreator("BenchVault documentation builder")
    canvas.saveState()
    canvas.setFillColor(PAPER)
    canvas.rect(0, 0, PAGE_WIDTH, PAGE_HEIGHT, fill=1, stroke=0)
    canvas.setFillColor(NIH_BLUE_DARK)
    canvas.rect(0, PAGE_HEIGHT - 0.12 * inch, PAGE_WIDTH, 0.12 * inch, fill=1, stroke=0)
    canvas.setStrokeColor(NIH_GOLD)
    canvas.setLineWidth(1.1)
    canvas.line(MARGIN_X, PAGE_HEIGHT - 0.24 * inch, PAGE_WIDTH - MARGIN_X, PAGE_HEIGHT - 0.24 * inch)
    canvas.setFont("Helvetica", 7.5)
    canvas.setFillColor(MUTED)
    canvas.drawRightString(
        PAGE_WIDTH - MARGIN_X,
        0.38 * inch,
        "Local credentials, notebook IDs, source PDFs, and backups stay outside GitHub.",
    )
    canvas.restoreState()


def draw_page_number(canvas, _doc) -> None:
    canvas.saveState()
    canvas.setFont("Helvetica", 7.5)
    canvas.setFillColor(MUTED)
    canvas.drawCentredString(PAGE_WIDTH / 2, 0.34 * inch, str(canvas.getPageNumber()))
    canvas.restoreState()


def draw_later_page(canvas, doc) -> None:
    canvas.saveState()
    canvas.setStrokeColor(NIH_BLUE_DARK)
    canvas.setLineWidth(0.7)
    canvas.line(MARGIN_X, PAGE_HEIGHT - 0.42 * inch, PAGE_WIDTH - MARGIN_X, PAGE_HEIGHT - 0.42 * inch)
    canvas.setFillColor(NIH_BLUE_DARK)
    canvas.setFont("Helvetica-Bold", 8)
    canvas.drawString(MARGIN_X, PAGE_HEIGHT - 0.31 * inch, "BenchVault Quickstart")
    canvas.setFillColor(MUTED)
    canvas.setFont("Helvetica", 7.5)
    canvas.drawRightString(PAGE_WIDTH - MARGIN_X, PAGE_HEIGHT - 0.31 * inch, "LabArchives GOV backup guide")
    canvas.setStrokeColor(RULE)
    canvas.setLineWidth(0.4)
    canvas.line(MARGIN_X, 0.52 * inch, PAGE_WIDTH - MARGIN_X, 0.52 * inch)
    canvas.setFont("Helvetica", 7.5)
    canvas.setFillColor(MUTED)
    canvas.drawString(MARGIN_X, 0.34 * inch, "Keep credentials and raw backups local.")
    canvas.restoreState()
    draw_page_number(canvas, doc)


def main() -> None:
    document = SimpleDocTemplate(
        str(OUTPUT),
        pagesize=letter,
        rightMargin=MARGIN_X,
        leftMargin=MARGIN_X,
        topMargin=0.62 * inch,
        bottomMargin=0.68 * inch,
        title="BenchVault Quickstart",
        author="BenchVault",
    )
    document.build(
        build_story(),
        onFirstPage=draw_first_page,
        onLaterPages=draw_later_page,
    )
    print(OUTPUT.relative_to(ROOT))


if __name__ == "__main__":
    main()
