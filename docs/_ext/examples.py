"""Generate the Examples section (``docs/examples/``, gitignored) from ``matlab/examples``.

Each ``nominalexample_*.m`` becomes a page showing the script, plus an index. The page title
is the file's label below; its lead line is the file's first help line
(``%NOMINALEXAMPLE_FOO  Summary.``); the file name is the code block's caption. Add a demo and
it appears, under its file name until it gets a label. Files are rewritten only when their
content changes.
"""

from __future__ import annotations

import re
from pathlib import Path

from sphinx.application import Sphinx

REPO = "https://github.com/nominal-io/matlab-client-rs"

# file -> sidebar label, in sidebar order. Demos not listed follow, under their file name.
DEMOS = {
    "nominalexample_alldemos": "All demos",
    "nominalexample_assetdemo": "Assets",
    "nominalexample_datasetdemo": "Datasets and units",
    "nominalexample_rundemo": "Runs",
    "nominalexample_eventdemo": "Events",
    "nominalexample_uploaddemo": "Writing and ingesting",
    "nominalexample_streamdemo": "Streaming",
    "nominalexample_analysisdemo": "Reading data back",
}
# small functions the demos call: listed last, in their own group on the index
HELPERS = {
    "nominalexample_connect": "Helper: connect",
    "nominalexample_publish": "Helper: publish results",
}

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


def _summary(m: Path) -> str:
    text = m.read_text(encoding="utf-8", errors="replace")
    h1 = re.search(r"^%([A-Z][A-Z0-9_]*)\s{2,}(.*)$", text, re.M)
    return h1.group(2).strip().rstrip(".") if h1 else ""


def _order(stem: str) -> tuple[int, int, str]:
    if stem in DEMOS:
        return (0, list(DEMOS).index(stem), stem)
    if stem in HELPERS:
        return (2, list(HELPERS).index(stem), stem)
    return (1, 0, stem)


def _write(path: Path, content: str) -> None:
    if not path.exists() or path.read_text(encoding="utf-8") != content:
        path.write_text(content, encoding="utf-8")


def generate(app: Sphinx) -> None:
    src = Path(app.config.matlab_src_dir) / "examples"
    out = Path(app.srcdir) / "examples"
    out.mkdir(exist_ok=True)

    scripts = sorted(src.glob("nominalexample_*.m"), key=lambda p: _order(p.stem))
    entries = []  # (stem, label, summary)
    for m in scripts:
        rel = m.relative_to(Path(app.config.matlab_src_dir).parent).as_posix()
        label = DEMOS.get(m.stem) or HELPERS.get(m.stem) or m.stem
        summary = _summary(m)
        entries.append((m.stem, label, summary))
        lead = f"{{.lead}}\n{summary}.\n\n" if summary else ""
        _write(
            out / f"{m.stem}.md",
            f"# {label}\n\n{lead}"
            f"```{{literalinclude}} /../{rel}\n:language: matlab\n:caption: {m.name}\n```\n\n"
            f"Source: [`{rel}`]({REPO}/blob/main/{rel})\n",
        )

    def bullets(rows: list[tuple[str, str, str]]) -> str:
        return "".join(f"- [{label}]({stem}.md): `{stem}`. {summary}.\n" for stem, label, summary in rows)

    demos = [e for e in entries if e[0] not in HELPERS]
    helpers = [e for e in entries if e[0] in HELPERS]
    body = "## Demos\n\n" + bullets(demos)
    if helpers:
        body += "\n## Helpers\n\nSmall functions the demos call.\n\n" + bullets(helpers)
    toc = "".join(f"{stem}\n" for stem, _, _ in entries)
    _write(out / "index.md", INTRO + body + f"\n```{{toctree}}\n:hidden:\n\n{toc}```\n")
    keep = {f"{stem}.md" for stem, _, _ in entries} | {"index.md"}
    for stale in out.glob("*.md"):
        if stale.name not in keep:
            stale.unlink()


def setup(app: Sphinx) -> dict[str, object]:
    app.connect("builder-inited", generate)
    return {"version": "0.1", "parallel_read_safe": True}
