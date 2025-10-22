#!/bin/bash

if [ ! -d ".venv" ]; then
    python -m venv .venv
    source .venv/bin/activate
fi

pip install python-appimage

python-appimage build app --python-version 3.13 --name OSCR AppImage

