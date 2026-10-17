"""CSV export for the stats reads (#98 DEC-B, brief DEC-11).

`text/csv; charset=utf-8`, sent as an attachment, header row first, no
byte-order mark, RFC 4180 quoting by the stdlib writer (CRLF line ends).
A cell that a spreadsheet would run as a formula - one starting with `=`,
`+`, `-`, `@`, a tab or a carriage return - is prefixed with `'`: a host
name or a sniffed name is whatever a LAN device sent, so an export must
never be a way to plant a formula in the operator's spreadsheet (OWASP CSV
injection). Numbers are written as numbers and never touched.
"""

import csv
import io
from typing import Annotated, Literal

from fastapi import Query
from fastapi.responses import Response

Format = Literal["json", "csv"]
FormatParam = Annotated[Format, Query(
    alias="format",
    description="`json` (the default) or `csv`: the same rows as a "
                "`text/csv; charset=utf-8` attachment, header row first, no "
                "byte-order mark. A text cell that starts with `=`, `+`, "
                "`-`, `@`, a tab or a carriage return is prefixed with `'` "
                "so a spreadsheet shows it as text")]

# The OpenAPI entry for a route that can answer in CSV.
CSV_RESPONSES = {200: {"content": {"text/csv": {"schema": {"type": "string"}}},
                       "description": "JSON, or CSV with `format=csv`"}}

_FORMULA_LEADS = ("=", "+", "-", "@", "\t", "\r")


def cell(value):
    """VALUE as written to a CSV cell."""
    if isinstance(value, str) and value.startswith(_FORMULA_LEADS):
        return "'" + value
    return value


def render(header: list, rows) -> str:
    buf = io.StringIO()
    writer = csv.writer(buf)
    writer.writerow(header)
    for row in rows:
        writer.writerow([cell(v) for v in row])
    return buf.getvalue()


def response(header: list, rows, filename: str) -> Response:
    """A CSV attachment. FILENAME is built from validated parameters only."""
    return Response(
        content=render(header, rows),
        media_type="text/csv; charset=utf-8",
        headers={"Content-Disposition": f'attachment; filename="{filename}"'})
