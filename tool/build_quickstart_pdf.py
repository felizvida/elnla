#!/usr/bin/env python3
"""Build the ELNLA quickstart PDF from docs/user/quickstart.md."""

from __future__ import annotations

import re
from pathlib import Path
from xml.sax.saxutils import escape

from reportlab.lib import colors
from reportlab.lib.pagesizes import letter
from reportlab.lib.styles import ParagraphStyle, getSampleStyleSheet
from reportlab.lib.units import inch
from reportlab.lib.utils import ImageReader
from reportlab.platypus import (
    Image,
    ListFlowable,
    ListItem,
    Paragraph,
    Preformatted,
    SimpleDocTemplate,
    Spacer,
)


ROOT = Path(__file__).resolve().parents[1]
SOURCE = ROOT / "docs/user/quickstart.md"
OUTPUT = ROOT / "docs/user/ELNLA_Quickstart.pdf"


def styles() -> dict[str, ParagraphStyle]:
    base = getSampleStyleSheet()
    return {
        "title": ParagraphStyle(
            name="TitleNIH",
            parent=base["Title"],
            fontName="Helvetica-Bold",
            fontSize=24,
            leading=30,
            textColor=colors.HexColor("#162e51"),
            spaceAfter=12,
        ),
        "h1": ParagraphStyle(
            name="H1NIH",
            parent=base["Heading1"],
            fontName="Helvetica-Bold",
            fontSize=18,
            leading=23,
            textColor=colors.HexColor("#005ea2"),
            spaceBefore=14,
            spaceAfter=8,
        ),
        "h2": ParagraphStyle(
            name="H2NIH",
            parent=base["Heading2"],
            fontName="Helvetica-Bold",
            fontSize=14,
            leading=18,
            textColor=colors.HexColor("#162e51"),
            spaceBefore=10,
            spaceAfter=6,
        ),
        "body": ParagraphStyle(
            name="BodyNIH",
            parent=base["BodyText"],
            fontName="Helvetica",
            fontSize=10.5,
            leading=14,
            spaceAfter=6,
        ),
        "bullet": ParagraphStyle(
            name="BulletNIH",
            parent=base["BodyText"],
            fontName="Helvetica",
            fontSize=10.3,
            leading=13,
            leftIndent=12,
            firstLineIndent=0,
            spaceAfter=3,
        ),
        "code": ParagraphStyle(
            name="CodeNIH",
            parent=base["Code"],
            fontName="Courier",
            fontSize=8.8,
            leading=11,
            backColor=colors.HexColor("#f1f3f6"),
            borderColor=colors.HexColor("#d0d7de"),
            borderWidth=0.5,
            borderPadding=5,
            spaceBefore=4,
            spaceAfter=8,
        ),
    }


def inline_markdown(value: str) -> str:
    text = escape(value)
    text = re.sub(r"`([^`]+)`", r'<font face="Courier">\1</font>', text)
    text = re.sub(r"\*\*([^*]+)\*\*", r"<b>\1</b>", text)
    return text


def image_flowable(path_text: str):
    clean = path_text.split("{", 1)[0].strip()
    image_path = (SOURCE.parent / clean).resolve()
    if not image_path.exists():
        image_path = (ROOT / clean).resolve()
    if not image_path.exists():
        return None
    reader = ImageReader(str(image_path))
    width, height = reader.getSize()
    max_width = 6.8 * inch
    max_height = 3.0 * inch
    scale = min(max_width / width, max_height / height, 1)
    return Image(str(image_path), width=width * scale, height=height * scale)


def append_paragraph(story: list, paragraph: list[str], style: ParagraphStyle) -> None:
    text = " ".join(line.strip() for line in paragraph if line.strip())
    if text:
        story.append(Paragraph(inline_markdown(text), style))
    paragraph.clear()


def build_story() -> list:
    st = styles()
    story: list = []
    paragraph: list[str] = []
    bullets: list[str] = []
    numbers: list[str] = []
    code: list[str] = []
    in_code = False

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

    lines = SOURCE.read_text(encoding="utf-8").splitlines()
    if lines and lines[0].strip() == "---":
        for index, line in enumerate(lines[1:], start=1):
            if line.strip() == "---":
                lines = lines[index + 1 :]
                break

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
                in_code = True
                code = []
            continue
        if in_code:
            code.append(raw)
            continue

        image_match = re.match(r"!\[[^]]*]\(([^)]+)\)", raw)
        if image_match:
            append_paragraph(story, paragraph, st["body"])
            flush_lists()
            flowable = image_flowable(image_match.group(1))
            if flowable is not None:
                story.extend([flowable, Spacer(1, 8)])
            continue

        if raw.startswith("# "):
            append_paragraph(story, paragraph, st["body"])
            flush_lists()
            story.append(Paragraph(inline_markdown(raw[2:]), st["title"]))
            continue
        if raw.startswith("## "):
            append_paragraph(story, paragraph, st["body"])
            flush_lists()
            story.append(Paragraph(inline_markdown(raw[3:]), st["h1"]))
            continue
        if raw.startswith("### "):
            append_paragraph(story, paragraph, st["body"])
            flush_lists()
            story.append(Paragraph(inline_markdown(raw[4:]), st["h2"]))
            continue
        if raw.startswith("- "):
            append_paragraph(story, paragraph, st["body"])
            numbers = []
            bullets.append(raw[2:])
            continue
        if bullets and raw.startswith("  ") and raw.strip():
            bullets[-1] = f"{bullets[-1]} {raw.strip()}"
            continue
        numbered = re.match(r"\d+\.\s+(.*)", raw)
        if numbered:
            append_paragraph(story, paragraph, st["body"])
            bullets = []
            numbers.append(numbered.group(1))
            continue
        if numbers and raw.startswith("  ") and raw.strip():
            numbers[-1] = f"{numbers[-1]} {raw.strip()}"
            continue
        if not raw.strip():
            append_paragraph(story, paragraph, st["body"])
            flush_lists()
            story.append(Spacer(1, 3))
            continue
        paragraph.append(raw)

    append_paragraph(story, paragraph, st["body"])
    flush_lists()
    return story


def draw_page(canvas, _doc) -> None:
    canvas.saveState()
    canvas.setFillColor(colors.HexColor("#162e51"))
    canvas.rect(0, letter[1] - 0.38 * inch, letter[0], 0.38 * inch, fill=1)
    canvas.setFillColor(colors.white)
    canvas.setFont("Helvetica-Bold", 10)
    canvas.drawString(0.55 * inch, letter[1] - 0.25 * inch, "ELNLA Quickstart")
    canvas.setFillColor(colors.HexColor("#60717d"))
    canvas.setFont("Helvetica", 8)
    canvas.drawRightString(letter[0] - 0.55 * inch, 0.35 * inch, str(canvas.getPageNumber()))
    canvas.restoreState()


def main() -> None:
    document = SimpleDocTemplate(
        str(OUTPUT),
        pagesize=letter,
        rightMargin=0.55 * inch,
        leftMargin=0.55 * inch,
        topMargin=0.65 * inch,
        bottomMargin=0.55 * inch,
        title="ELNLA Quickstart",
    )
    document.build(build_story(), onFirstPage=draw_page, onLaterPages=draw_page)
    print(OUTPUT.relative_to(ROOT))


if __name__ == "__main__":
    main()
