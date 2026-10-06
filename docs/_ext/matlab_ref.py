"""Generate the Reference section (``docs/ref/``, gitignored) from the ``+nominal`` source.

One page per class, one page for the free functions, and an index listing each with the
summary line of its help text. Nothing here is hand-maintained: add a file to ``+nominal``
and it appears. Files are rewritten only when their content changes, so live preview
doesn't loop.
"""

from __future__ import annotations

import re
from pathlib import Path

from sphinx.application import Sphinx

EXCLUDE = {"Resource"}  # the handle base class: internal, nothing a user calls


def _summary(text: str) -> str:
    m = re.search(r"^\s*%\s*[A-Z][A-Z0-9_]*\s{2,}(.*)$", text, re.M)
    return m.group(1).strip() if m else ""


def _write(path: Path, content: str) -> None:
    if not path.exists() or path.read_text(encoding="utf-8") != content:
        path.write_text(content, encoding="utf-8")


def generate(app: Sphinx) -> None:
    src = Path(app.config.matlab_src_dir) / "+nominal"
    out = Path(app.srcdir) / "ref"
    out.mkdir(exist_ok=True)

    classes: list[tuple[str, str]] = []
    functions: list[tuple[str, str]] = []
    for m in sorted(src.glob("*.m"), key=lambda p: p.stem.lower()):
        text = m.read_text(encoding="utf-8", errors="replace")
        if m.stem in EXCLUDE:
            continue
        (classes if re.search(r"^\s*classdef\b", text, re.M) else functions).append((m.stem, _summary(text)))

    for name, summary in classes:
        _write(
            out / f"{name}.md",
            f"# {name}\n\n```{{eval-rst}}\n.. autoclass:: nominal.{name}\n"
            f"   :members:\n   :undoc-members:\n   :exclude-members: {name}\n```\n",
        )
    functions_page = "# Functions\n\nFree functions in the `nominal` namespace.\n\n" + "".join(
        f"```{{eval-rst}}\n.. autofunction:: nominal.{name}\n```\n\n" for name, _ in functions
    )
    _write(out / "functions.md", functions_page)

    rows = "".join(f"- {{class}}`nominal.{n}`: {s}\n" for n, s in classes)
    frows = "".join(f"- {{func}}`nominal.{n}`: {s}\n" for n, s in functions)
    toc = "".join(f"{n}\n" for n, _ in classes) + "functions\n"
    _write(
        out / "index.md",
        "# Reference\n\nEvery class and function, generated from the help text in `+nominal`. "
        "The same text is available in MATLAB with `help nominal.Client` and friends.\n\n"
        f"## Classes\n\n{rows}\n## Functions\n\n{frows}\n"
        f"```{{toctree}}\n:hidden:\n\n{toc}```\n",
    )
    # remove pages for classes that no longer exist
    keep = {f"{n}.md" for n, _ in classes} | {"functions.md", "index.md"}
    for stale in out.glob("*.md"):
        if stale.name not in keep:
            stale.unlink()


def setup(app: Sphinx) -> dict[str, object]:
    app.connect("builder-inited", generate)
    return {"version": "0.1", "parallel_read_safe": True}
