#!/bin/bash

# Utility script to start the documentation server
# Checks if mkdocs is installed, if not, prints instructions.

if ! command -v mkdocs &> /dev/null
then
    echo "❌ mkdocs could not be found."
    echo "To install the documentation tools, run:"
    echo ""
    echo "    pip install mkdocs-material"
    echo ""
    exit 1
fi

echo "🚀 Starting Documentation Server..."
echo "👉 Open http://127.0.0.1:8000 in your browser"
mkdocs serve
