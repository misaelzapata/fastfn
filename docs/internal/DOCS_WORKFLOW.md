# Docs Maintenance Workflow

This project uses **MkDocs** with the **Material for MkDocs** theme to generate a high-quality, static documentation site similar to FastAPI.

## Prerequisites

You need Python installed.

```bash
# Provide a venv if you prefer
python3 -m venv .venv
source .venv/bin/activate

# Install the dependencies
pip install mkdocs-material
```

## Running the Docs Locally

To preview your changes with hot-reloading:

```bash
# From the project root
mkdocs serve
```

This will start a local server at [http://127.0.0.1:8000](http://127.0.0.1:8000).

## Building describing for Production

To build the static site (html/css/js) into a `site/` folder:

```bash
mkdocs build
```

## Structure Strategy

We follow strict **Code Separation**:

*   **Structure**: Defined in `mkdocs.yml` at the project root.
*   **Content**: Located in `docs/en` and `docs/es`.
*   **Assets**: Images and other assets should go in `docs/img`.

### Adding new pages

1.  Create the `.md` file in the appropriate folder (`tutorial`, `how-to`, etc).
2.  Open `mkdocs.yml`.
3.  Add the path to the `nav` section under the correct language and category.

### Special Features Used

*   **Admonitions**: `!!! info "Title"` or `!!! warning`
*   **Code Tabs**:
    ```markdown
    === "Python"
        code...
    === "Node"
        code...
    ```
*   **Icons**: `:material-name:` (used in index pages)

## Troubleshooting

If `mkdocs` command is not found, ensure your python bin folder is in your PATH or use `python -m mkdocs serve`.
