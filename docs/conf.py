"""Sphinx config for the Nominal for MATLAB docs. Reference pages come from the +nominal source."""

import sys
from pathlib import Path

from nominal_sphinx_theme import theme_options

HERE = Path(__file__).parent
sys.path.insert(0, str(HERE / "_ext"))

project = "MATLAB"
copyright = "Nominal, Inc."

extensions = [
    "myst_parser",
    "sphinx.ext.autodoc",
    "sphinxcontrib.matlab",
    "sphinx_design",
    "sphinx_copybutton",
    "nominal_sphinx_theme",
    "matlab_help",
    "sphinx.ext.napoleon",
    "matlab_ref",
    "examples",
]
myst_enable_extensions = ["colon_fence", "deflist", "attrs_inline", "attrs_block", "fieldlist"]
myst_heading_anchors = 6

# -- MATLAB domain -------------------------------------------------------------
matlab_src_dir = str(HERE.parent / "matlab")
primary_domain = "mat"
matlab_keep_package_prefix = True   # objects register as nominal.X, which See also links use
matlab_short_links = False
matlab_auto_link = None  # See also links are made by _ext/matlab_help.py
autodoc_member_order = "bysource"

html_theme = "shibuya"
html_title = project
html_copy_source = False
html_static_path = ["_static"]
html_css_files = ["custom.css"]
html_context = {
    "source_type": "github",
    "source_user": "nominal-io",
    "source_repo": "matlab-client-rs",
    "source_version": "main",
    "source_docs_path": "/docs/",
}
html_theme_options = theme_options(
    github_url="https://github.com/nominal-io/matlab-client-rs",
    nav_links=[
        {"title": "Guides", "url": "index"},
        {"title": "Examples", "url": "examples/index"},
        {"title": "Reference", "url": "ref/index"},
    ],
)

# Napoleon renders optional Args:/Returns: sections; matlab_help runs first and leaves them alone.
napoleon_google_docstring = True
napoleon_numpy_docstring = False
napoleon_use_rtype = False
# Name=Value options get their own section, rendered like Args:. The signature only shows them
# as `options`, so this is where a reader finds them.
napoleon_custom_sections = [("Options", "params_style")]
