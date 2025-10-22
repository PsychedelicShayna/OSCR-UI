#!/bin/bash

set -euo pipefail

if [ ! -d ".venv" ]; then
    python -m venv .venv
    source .venv/bin/activate
fi

python -m pip install python-appimage
echo "-e $PWD" > ./AppImage/requirements.txt

python-appimage build app --python-version 3.13 --name OSCR AppImage

