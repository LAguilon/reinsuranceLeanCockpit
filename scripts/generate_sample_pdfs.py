#!/usr/bin/env python3
"""Generate realistic reinsurance contract slips as PDF 1.4 files.

Pure standard library: no reportlab, no fpdf. The point is that the same bytes a
broker would email can be produced, parsed and validated end to end without a
single dependency, which is what makes the pipeline auditable.

Usage: python3 scripts/generate_sample_pdfs.py
"""

from pathlib import Path


def escape_pdf_text(s: str) -> str:
    return s.replace("\\", r"\\").replace("(", r"\(").replace(")", r"\)")


def write_simple_pdf(filepath: str, lines: list[str]) -> None:
    """Write a one-page PDF 1.4 file with Helvetica text, one line per list entry."""
    parts = ["BT", "/F1 9 Tf", "40 800 Td", "12 TL"]
    for line in lines:
        parts.append(f"({escape_pdf_text(line)}) Tj")
        parts.append("T*")
    parts.append("ET")
    stream = "\n".join(parts).encode("latin-1")

    bodies = [
        b"<< /Type /Catalog /Pages 2 0 R >>",
        b"<< /Type /Pages /Kids [3 0 R] /Count 1 >>",
        b"<< /Type /Page /Parent 2 0 R /MediaBox [0 0 595 842] "
        b"/Resources << /Font << /F1 4 0 R >> >> /Contents 5 0 R >>",
        b"<< /Type /Font /Subtype /Type1 /BaseFont /Helvetica >>",
        b"<< /Length " + str(len(stream)).encode() + b" >>\nstream\n" + stream + b"\nendstream",
    ]

    out = bytearray(b"%PDF-1.4\n%\xe2\xe3\xcf\xd3\n")
    offsets = [0]
    for i, body in enumerate(bodies, start=1):
        offsets.append(len(out))
        out += f"{i} 0 obj\n".encode() + body + b"\nendobj\n"

    xref_pos = len(out)
    count = len(bodies) + 1
    out += f"xref\n0 {count}\n".encode()
    out += b"0000000000 65535 f \n"
    for off in offsets[1:]:
        out += f"{off:010d} 00000 n \n".encode()
    out += (
        f"trailer\n<< /Size {count} /Root 1 0 R >>\n"
        f"startxref\n{xref_pos}\n%%EOF\n"
    ).encode()

    Path(filepath).parent.mkdir(parents=True, exist_ok=True)
    with open(filepath, "wb") as fh:
        fh.write(bytes(out))


HEADER = [
    "MARKET REFORM CONTRACT (REINSURANCE SLIP)",
    "==================================================",
]

WORDING = [
    "--------------------------------------------------",
    "WORDING: Subject to standard hours clause and exact integer settlement.",
    "All amounts are expressed in minor units of the stated currency.",
    "Governing law: England and Wales. Arbitration: London, LCIA rules.",
    "Signed for and on behalf of the reinsurer by duly authorised signatory.",
]


def slip_lines(fields: list[tuple[str, str]]) -> list[str]:
    lines = list(HEADER)
    lines += [f"{k}: {v}" for k, v in fields]
    lines += WORDING
    return lines


SLIP_01_FIELDS = [
    ("Contract_ID", "CNT-WS-GAP-FIX"),
    ("Contract_Name", "US Windstorm Gap Closing Layer 10M xs 20M"),
    ("Counterparty", "Swiss Re Zurich"),
    ("Credit_Rating", "AA"),
    ("Direction", "Outward"),
    ("Currency", "USD"),
    ("Perils", "Windstorm"),
    ("Inuring_Priority", "10"),
    ("Contract_Type", "XoL"),
    ("Attachment", "20000000"),
    ("Occurrence_Limit", "10000000"),
    ("Aggregate_Limit", "20000000"),
    ("Reinstatement_Rate_Bps", "10000"),
    ("Base_Premium", "400000"),
]

SLIP_02_FIELDS = [
    ("Contract_ID", "CNT-EQ-CAYMAN-99"),
    ("Contract_Name", "Japan Earthquake Retro Layer 10M xs 15M (EUR)"),
    ("Counterparty", "Cayman Cell 99"),
    ("Credit_Rating", "Unrated"),
    ("Direction", "Outward"),
    ("Currency", "EUR"),
    ("Perils", "Earthquake"),
    ("Inuring_Priority", "10"),
    ("Contract_Type", "XoL"),
    ("Attachment", "15000000"),
    ("Occurrence_Limit", "10000000"),
    ("Aggregate_Limit", "10000000"),
    ("Reinstatement_Rate_Bps", "0"),
    ("Base_Premium", "1100000"),
]

SLIP_03_FIELDS = [
    ("Contract_ID", "CNT-CY-BROKER-TYPO"),
    ("Contract_Name", "Cyber Outward Quota Share 115 Percent (broker typo)"),
    ("Counterparty", "Meridian Re"),
    ("Credit_Rating", "A"),
    ("Direction", "Outward"),
    ("Currency", "EUR"),
    ("Perils", "Cyber"),
    ("Inuring_Priority", "10"),
    ("Contract_Type", "QuotaShare"),
    ("Share_Bps", "11500"),
    ("Event_Cap", "12000000"),
    ("Commission_Bps", "2000"),
]

SLIPS = [
    ("SLIP_01_Valid_Gap_Closer_USD.pdf", SLIP_01_FIELDS),
    ("SLIP_02_Trap_Unrated_FX_Mismatch.pdf", SLIP_02_FIELDS),
    ("SLIP_03_Illegal_115pct_QuotaShare.pdf", SLIP_03_FIELDS),
]


def main() -> None:
    base = Path(__file__).resolve().parent.parent / "examples" / "slips"
    base.mkdir(parents=True, exist_ok=True)
    for name, fields in SLIPS:
        lines = slip_lines(fields)
        write_simple_pdf(str(base / name), lines)
        (base / name.replace(".pdf", ".txt")).write_text("\n".join(lines) + "\n", encoding="utf-8")
        print(f"wrote {base / name} ({len(lines)} lines)")


if __name__ == "__main__":
    main()
