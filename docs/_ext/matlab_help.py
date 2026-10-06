"""Render MathWorks-style help text as reST.

MATLAB ``help`` is the first-class consumer of the help comments in ``+nominal``, so they keep
MathWorks conventions: ``%NAME  Summary.`` on the first line, examples as indented blocks,
two-column argument tables, and a trailing ``See also A, B``. This hook rewrites each docstring
on its way into Sphinx (``autodoc-process-docstring``) so the same text renders well on the web:

- the leading ``NAME`` is dropped from the summary line;
- an indented block becomes a MATLAB code block;
- consecutive ``name   description`` lines become a field list;
- ``See also`` becomes a ``seealso`` box whose known names link to their reference entries;
- ``Args:``, ``Options:`` and ``Returns:`` sections pass through untouched for napoleon, which renders them
  as parameter lists. This hook runs first (priority 400) so it can step around them.

Set ``MATLAB_HELP_DEBUG=Asset.getOrCreateDataset,Dataset.write`` to print before/after lines.
"""

from __future__ import annotations

import os
import re
from pathlib import Path

from sphinx.application import Sphinx

_SUMMARY = re.compile(r"^([A-Z][A-Z0-9_]*)\s{2,}(.*)$")
_SEE_ALSO = re.compile(r"^\s*See also:?\s*(.*)$", re.IGNORECASE)
# Napoleon section headers. Their bodies are napoleon's to render, so the adapter leaves them alone.
# Example: is not here: napoleon renders its body as prose, so the adapter turns it into code.
_NAPOLEON = re.compile(
    r"^\s*(Args|Options|Arguments|Parameters|Keyword Args|Keyword Arguments|Other Parameters|"
    r"Returns|Return|Yields|Yield|Raises|Raise|Attributes)\s*:\s*$"
)
_LIST_ITEM = re.compile(r"^(\s*)(\d+\.|[-*])\s+")
_TWO_COL = re.compile(r"^(\S[\w.=]*)\s{2,}(\S.*)$")
_CODE_INDENT = 4  # nested examples are indented one level deeper than prose
# a MATLAB statement: optional assignment, a call or expression, optional ; and % comment.
# Usage examples right after the summary sit at prose indent (MathWorks convention), so
# indentation alone cannot find them.
_STATEMENT = re.compile(
    r"^\s*(?:\[?[\w,\s]+\]?\s*=\s*)?[\w.]+(?:\(.*\)|\.\w+)\s*;?\s*(?:%.*)?$|^\s*[\w.]+\(.*\)\s*;?\s*(?:%.*)?$"
)

# lower-case name -> (role, proper name), built from the MATLAB source once per build
_KNOWN: dict[str, tuple[str, str]] = {}


def _index_source(src_dir: Path) -> None:
    pkg = src_dir / "+nominal"
    for m in sorted(pkg.glob("*.m")):
        text = m.read_text(encoding="utf-8", errors="replace")
        name = m.stem
        if re.search(r"^\s*classdef\b", text, re.M):
            _KNOWN[f"nominal.{name}".lower()] = ("class", f"nominal.{name}")
            for meth in re.findall(r"^\s*function\s+(?:\[?[\w,\s]*\]?\s*=\s*)?(\w+)\s*\(", text, re.M):
                if meth.startswith("get.") or meth == name:
                    continue
                full = f"nominal.{name}.{meth}"
                _KNOWN[full.lower()] = ("meth", full)
                _KNOWN[f"nominal.{name}/{meth}".lower()] = ("meth", full)
        else:
            _KNOWN[f"nominal.{name}".lower()] = ("func", f"nominal.{name}")


def _see_also_target(token: str) -> str:
    key = token.strip().lower()
    if key in _KNOWN:
        role, proper = _KNOWN[key]
        return f":{role}:`{proper}`"
    # a MATLAB builtin (RETIME) or anything we can't resolve: plain code, lower-cased
    return f"``{token.strip().lower()}``"


def _is_code_line(line: str) -> bool:
    return bool(line.strip()) and len(line) - len(line.lstrip()) >= _CODE_INDENT


def _paragraph(lines: list[str], i: int) -> int:
    """Index one past the last non-blank line of the paragraph starting at i."""
    j = i
    while j < len(lines) and lines[j].strip():
        j += 1
    return j


def _joined(para: list[str]) -> list[str]:
    """The paragraph's lines with MATLAB `...` continuations joined into one statement each."""
    out, cur = [], ""
    for p in para:
        s = p.rstrip()
        cur = f"{cur} {s.strip()}" if cur else s
        if cur.endswith("..."):
            cur = cur[:-3].rstrip()
            continue
        out.append(cur)
        cur = ""
    if cur:
        out.append(cur)
    return out


def _is_statement_para(para: list[str]) -> bool:
    return bool(para) and all(_STATEMENT.match(x) for x in _joined(para))


def _second_column(line: str) -> int | None:
    """Column where the description starts in a `name   description` line, else None."""
    m = re.match(r"^([A-Za-z_][\w.=]*)(\s+)(\S)", line)
    if not m or len(line) - len(line.lstrip()) != 0:
        return None
    return len(m.group(1)) + len(m.group(2))


def transform(lines: list[str]) -> list[str]:
    out: list[str] = []
    i = 0
    n = len(lines)

    # 1. summary line: "FETCH  Read one channel..." -> "Read one channel..."
    if lines and (m := _SUMMARY.match(lines[0].strip())):
        lines = [m.group(2)] + lines[1:]

    list_text_indent: int | None = None  # continuation indent of the current list item

    while i < n:
        line = lines[i]
        stripped = line.strip()

        # 2. See also -> seealso box
        if m := _SEE_ALSO.match(line):
            names = [t for t in re.split(r"[,\s]+", m.group(1)) if t]
            while i + 1 < n and lines[i + 1].strip() and not _SEE_ALSO.match(lines[i + 1]):
                # continuation line of a wrapped See also
                names += [t for t in re.split(r"[,\s]+", lines[i + 1].strip()) if t]
                i += 1
            out += ["", ".. seealso::", "", "   " + ", ".join(_see_also_target(t) for t in names), ""]
            i += 1
            continue

        # napoleon section: header plus its indented body, untouched
        if _NAPOLEON.match(line):
            head_indent = len(line) - len(line.lstrip())
            out.append(line)
            i += 1
            while i < n:
                nxt = lines[i]
                if nxt.strip() and len(nxt) - len(nxt.lstrip()) <= head_indent:
                    break
                if not nxt.strip() and (i + 1 >= n or not lines[i + 1].strip()
                                        or len(lines[i + 1]) - len(lines[i + 1].lstrip()) <= head_indent):
                    break
                out.append(nxt)
                i += 1
            out.append("")
            continue

        # track list items so their continuation lines are not mistaken for code
        if m := _LIST_ITEM.match(line):
            list_text_indent = len(m.group(0))
            out.append(line)
            i += 1
            continue
        if not stripped:
            if list_text_indent is not None and i + 1 < n and _LIST_ITEM.match(lines[i + 1]) is None:
                nxt = lines[i + 1]
                if nxt.strip() and len(nxt) - len(nxt.lstrip()) != list_text_indent:
                    list_text_indent = None
            out.append(line)
            i += 1
            continue
        indent = len(line) - len(line.lstrip())
        if list_text_indent is not None and indent == list_text_indent:
            out.append(line)
            i += 1
            continue
        list_text_indent = None

        # 3. an indented block, or a paragraph of statements -> code block
        j = _paragraph(lines, i)
        para = lines[i:j]
        if _is_statement_para(para) or _is_code_line(line):
            block: list[str] = []
            if _is_statement_para(para):
                # usage lines at prose indent, possibly wrapped with `...`: the whole paragraph
                block, i = list(para), j
            else:
                while i < n and (lines[i].strip() or (i + 1 < n and _is_code_line(lines[i + 1]))):
                    if not lines[i].strip() or _is_code_line(lines[i]) or _STATEMENT.match(lines[i]):
                        block.append(lines[i])
                        i += 1
                    else:
                        break
            while block and not block[-1].strip():
                block.pop()
            base = min(len(b) - len(b.lstrip()) for b in block if b.strip())
            if out and out[-1].strip():
                out.append("")
            out += [".. code-block:: matlab", ""] + ["   " + b[base:] if b.strip() else "" for b in block] + [""]
            continue

        # 4. a run of `name   description` lines aligned on one column -> definition list.
        # At least one line must pad with two or more spaces, or two prose lines that happen
        # to share a column ("Keep a call..." / "Past that, ...") would be caught too.
        cols = [_second_column(p) for p in para]
        padded = any(re.match(r"^\S+\s{2,}", p) for p in para)
        if len(para) >= 2 and padded and cols[0] is not None and all(c == cols[0] for c in cols):
            if out and out[-1].strip():
                out.append("")
            for p_ in para:
                out += [f"``{p_.split()[0]}``", f"   {p_[cols[0]:].strip()}"]
            out.append("")
            i = j
            continue

        out.append(line)
        i += 1
    return out


def _process(app: Sphinx, what: str, name: str, obj: object, options: object, lines: list[str]) -> None:
    debug = name in os.environ.get("MATLAB_HELP_DEBUG", "").split(",")
    if debug:
        print(f"\n--- {name}: before\n" + "\n".join(repr(l) for l in lines))
    new = transform(list(lines))
    lines[:] = new
    if debug:
        print(f"--- {name}: after\n" + "\n".join(new))


def setup(app: Sphinx) -> dict[str, object]:
    def on_inited(app: Sphinx) -> None:
        _index_source(Path(app.config.matlab_src_dir))

    app.connect("builder-inited", on_inited)
    app.connect("autodoc-process-docstring", _process, priority=400)  # before napoleon (500)
    return {"version": "0.1", "parallel_read_safe": True}
