"""Generate the Examples section (``docs/examples/``, gitignored) from ``matlab/examples``.

Each ``nominalexample_*.m`` becomes a page showing the script, titled from its first help
line (``%NOMINALEXAMPLE_FOO  Title.``), plus an index. Nothing here is hand-maintained: add a
demo and it appears. Files are rewritten only when their content changes.
"""

from __future__ import annotations

import re
from pathlib import Path

from sphinx.application import Sphinx

REPO = "https://github.com/nominal-io/nominal-matlab"
# shown first, in this order; the rest follow alphabetically
FIRST = ["nominalexample_alldemos"]

INTRO = """# Examples

{.lead}
Runnable demos, one task each. They ship inside the toolbox but are **not** on the path, so
their names cannot shadow anything in your session. Add them:

```matlab
addpath(fullfile(fileparts(fileparts(which('nominal.Client'))), 'examples'))
```

Every demo needs credentials (see [Authenticating](../guides/authenticating.md)) and leaves
its results in the base workspace as a struct, so there is something to inspect afterwards:

```matlab
nominalexample_uploaddemo
nominalexample_analysisdemo(nominalUpload.WrittenDatasetRid)

plot(nominalAnalysis.Samples.Time, nominalAnalysis.Samples.(1))
```

The demos create throwaway assets named `nominal-matlab-demo-<timestamp>`, so they are safe
to run repeatedly. Pass an asset name to use an existing one: `nominalexample_assetdemo("engine-3")`.

"""


def _title(m: Path) -> str:
    text = m.read_text(encoding="utf-8", errors="replace")
    h1 = re.search(r"^%([A-Z][A-Z0-9_]*)\s{2,}(.*)$", text, re.M)
    return h1.group(2).strip().rstrip(".") if h1 else m.stem


def _write(path: Path, content: str) -> None:
    if not path.exists() or path.read_text(encoding="utf-8") != content:
        path.write_text(content, encoding="utf-8")


def generate(app: Sphinx) -> None:
    src = Path(app.config.matlab_src_dir) / "examples"
    out = Path(app.srcdir) / "examples"
    out.mkdir(exist_ok=True)

    scripts = sorted(src.glob("nominalexample_*.m"), key=lambda p: (p.stem not in FIRST, FIRST.index(p.stem) if p.stem in FIRST else 0, p.stem))
    entries = []
    for m in scripts:
        rel = m.relative_to(Path(app.config.matlab_src_dir).parent).as_posix()
        title = _title(m)
        entries.append((m.stem, title))
        _write(
            out / f"{m.stem}.md",
            f"# {m.stem}\n\n{{.lead}}\n{title}.\n\n"
            f"```{{literalinclude}} /../{rel}\n:language: matlab\n```\n\n"
            f"Source: [`{rel}`]({REPO}/blob/main/{rel})\n",
        )
    links = "".join(f"- [`{stem}`]({stem}.md): {title}\n" for stem, title in entries)
    toc = "".join(f"{stem}\n" for stem, _ in entries)
    _write(out / "index.md", INTRO + links + f"\n```{{toctree}}\n:hidden:\n\n{toc}```\n")
    keep = {f"{stem}.md" for stem, _ in entries} | {"index.md"}
    for stale in out.glob("*.md"):
        if stale.name not in keep:
            stale.unlink()


def setup(app: Sphinx) -> dict[str, object]:
    app.connect("builder-inited", generate)
    return {"version": "0.1", "parallel_read_safe": True}
