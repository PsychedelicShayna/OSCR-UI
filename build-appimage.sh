#!/usr/bin/env bash
set -euo pipefail
# build-appimage.sh
# Produces a portable AppImage for OSCR-UI using a Manylinux Python AppImage
#
# Requirements on the machine: curl or wget, bsdtar or tar, fuse or loopback (for appimage extract),
# and 'chmod +x' support. Script will download appimagetool if missing.

# CONFIG
PY_VER_TAG="cp313-cp313"           # python tag we want inside the AppImage
MANYLINUX_TAG="manylinux2014_x86_64"
# fallback Manylinux AppImage filename (common form used by python-appimage releases)
MANYLINUX_FILENAME="python3.13.8-${PY_VER_TAG}-${MANYLINUX_TAG}.AppImage"
MANYLINUX_URL="https://github.com/niess/python-appimage/releases/download/python3.13/${MANYLINUX_FILENAME}"
APPIMAGETOOL_URL="https://github.com/AppImage/AppImageKit/releases/latest/download/appimagetool-x86_64.AppImage"

WORKDIR="$(pwd)"
DIST_DIR="${WORKDIR}/dist"
EXTRACT_DIR="${WORKDIR}/python3.13"    # extracted Manylinux runtime -> will become AppDir root
WHEEL_DIR="${WORKDIR}/dist"
WHEEL_PATH=""
APPDIR="${WORKDIR}/AppDir"             # final appdir (we will move/copy extracted root here)
OUT_NAME="OSCR"                        # final AppImage name prefix

# Helpers
msg(){ printf '\033[1;34m==>\033[0m %s\n' "$*"; }
err(){ printf '\033[1;31mERR:\033[0m %s\n' "$*" >&2; }

# 1) Build a wheel from local repo
msg "Cleaning old builds and building a wheel..."
rm -rf dist build *.egg-info || true
python -m pip install --upgrade pip build setuptools wheel >/dev/null
python -m build --wheel --outdir "${DIST_DIR}"

# pick the first wheel
WHEEL_PATH="$(ls "${WHEEL_DIR}"/*.whl 2>/dev/null | head -n1 || true)"
if [ -z "${WHEEL_PATH}" ]; then
  err "No wheel built in ${WHEEL_DIR}. Aborting."
  exit 1
fi
WHEEL_BASENAME="$(basename "${WHEEL_PATH}")"
msg "Found wheel: ${WHEEL_BASENAME}"

# 2) Ensure we have a Manylinux Python AppImage (download if necessary)
if [ ! -f "${MANYLINUX_FILENAME}" ]; then
  msg "Attempting to download Manylinux Python AppImage from ${MANYLINUX_URL} ..."
  if command -v curl >/dev/null 2>&1; then
    curl -L -f -o "${MANYLINUX_FILENAME}" "${MANYLINUX_URL}" || true
  elif command -v wget >/dev/null 2>&1; then
    wget -O "${MANYLINUX_FILENAME}" "${MANYLINUX_URL}" || true
  fi
fi

if [ ! -f "${MANYLINUX_FILENAME}" ]; then
  err "Could not download ${MANYLINUX_FILENAME}. Please install 'python-appimage' or provide a Manylinux Python AppImage."
  err "You can also set the variable MANYLINUX_FILENAME / MANYLINUX_URL to a working file."
  exit 1
fi
chmod +x "${MANYLINUX_FILENAME}"

# 3) Extract the Manylinux AppImage (produces squashfs-root)
rm -rf "${EXTRACT_DIR}" squashfs-root || true
msg "Extracting ${MANYLINUX_FILENAME} ..."
./"${MANYLINUX_FILENAME}" --appimage-extract
# move extraction to desired directory name
mv squashfs-root "${EXTRACT_DIR}"

# 4) Use the extracted python to install the wheel into the extracted runtime
# detect extracted python bin path (common layouts: opt/python3.13/bin or usr/bin)
# prefer opt/python3.13/bin as python-appimage uses opt in templates
if [ -x "${EXTRACT_DIR}/opt/python3.13/bin/pip" ]; then
  EXTRACTED_PIP="${EXTRACT_DIR}/opt/python3.13/bin/pip"
  EXTRACTED_PY="${EXTRACT_DIR}/opt/python3.13/bin/python"
elif [ -x "${EXTRACT_DIR}/usr/bin/pip" ]; then
  EXTRACTED_PIP="${EXTRACT_DIR}/usr/bin/pip"
  EXTRACTED_PY="${EXTRACT_DIR}/usr/bin/python"
else
  err "Can't locate pip in extracted runtime. Looked in opt/python3.13/bin and usr/bin."
  exit 1
fi

msg "Using extracted Python: ${EXTRACTED_PY}"

# upgrade packaging tools inside the extracted runtime
msg "Upgrading pip/setuptools inside extracted runtime..."
"${EXTRACTED_PIP}" install --upgrade pip setuptools wheel >/dev/null

# copy wheel into extracted runtime folder so pip can install it reliably from inside
mkdir -p "${EXTRACT_DIR}/wheels"
cp -v "${WHEEL_PATH}" "${EXTRACT_DIR}/wheels/${WHEEL_BASENAME}"

msg "Installing ${WHEEL_BASENAME} into the extracted runtime..."
# install wheel (no build step, pip will install cleanly)
"${EXTRACTED_PIP}" install "wheels/${WHEEL_BASENAME}"

# 5) Verify console script exists
if [ ! -x "${EXTRACT_DIR}/opt/python3.13/bin/oscr" ] && [ ! -x "${EXTRACT_DIR}/usr/bin/oscr" ]; then
  # try to detect any script name derived from entry_points
  msg "oscr launcher not found yet; searching site-packages for console_scripts entry..."
  # use python to print console_scripts entrypoints
  "${EXTRACTED_PY}" - <<PYCODE || true
import pkgutil, sys, importlib
try:
    import importlib.metadata as m
except Exception:
    import importlib_metadata as m
for dist in m.distributions():
    if 'OSCR' in dist.metadata.get('Name','') or 'OSCR-UI' in dist.metadata.get('Name',''):
        for entry in dist.entry_points:
            print("DIST:", dist.metadata.get('Name'), "-- ENTRY:", entry.name, entry.value)
PYCODE
  err "If no 'oscr' console_script exists after pip install, the package did not define a console script. Check pyproject.toml [project.scripts]."
  # continue anyway; script will try to run python -m main:Launcher.launch fallback
fi

# 6) Prepare AppDir (we'll use the extracted directory as base)
rm -rf "${APPDIR}"
msg "Preparing AppDir..."
# The extracted runtime already has a layout like: opt/python3.13/..., usr/, etc.
# We'll move the extracted tree to AppDir (but AppImage tools expect AppDir root)
mv "${EXTRACT_DIR}" "${APPDIR}"

# 7) Ensure AppRun exists (launcher)
APPRUN="${APPDIR}/AppRun"
cat > "${APPRUN:=${APPRUN}}" <<'EOF'
#!/bin/bash
set -e
HERE="$(dirname "$(readlink -f "${0}")")"
# prefer bundled python console script
if [ -x "$HERE/opt/python3.13/bin/oscr" ]; then
    exec "$HERE/opt/python3.13/bin/oscr" "$@"
fi
# fallback: try module execution with bundled python
if [ -x "$HERE/opt/python3.13/bin/python" ]; then
    exec "$HERE/opt/python3.13/bin/python" -m main "$@"
fi
# last resort
exec /bin/sh -c 'echo "Cannot find launcher inside AppImage." >&2; exit 1'
EOF
chmod +x "${APPRUN}"

# 8) Copy desktop file and icon into AppDir (for menu integration)
msg "Copying desktop file and icon..."
mkdir -p "${APPDIR}/usr/share/applications" "${APPDIR}/usr/share/icons/hicolor/64x64/apps"
cp -v AppImage/OSCR.desktop "${APPDIR}/usr/share/applications/" || true
# prefer packaged icon if present
if [ -f assets/oscr_icon_small.png ]; then
  cp -v assets/oscr_icon_small.png "${APPDIR}/usr/share/icons/hicolor/64x64/apps/oscr_icon_small.png"
fi
# copy appdata if exists
mkdir -p "${APPDIR}/usr/share/metainfo"
cp -v AppImage/OSCR.appdata.xml "${APPDIR}/usr/share/metainfo/" || true

# 9) Copy any extra assets to a fallback location inside AppDir and into site-packages if possible
msg "Copying assets/ into AppDir for safety..."
if [ -d assets ]; then
  mkdir -p "${APPDIR}/usr/share/oscr-assets"
  rsync -a assets/ "${APPDIR}/usr/share/oscr-assets/"
  # try copying into installed package site-packages if present
  SITEPKG_DIR="$("${EXTRACTED_PY}" -c "import os, sys, importlib; \
try: import oscr_ui as m; print(os.path.dirname(m.__file__)); \
except Exception: print('')")"
  if [ -n "${SITEPKG_DIR}" ]; then
    msg "Detected installed package path: ${SITEPKG_DIR} -- copying assets into package dir."
    rsync -a assets/ "${APPDIR}/${SITEPKG_DIR#/}" || true
  fi
fi

# 10) Ensure appimagetool is available
APPIMAGETOOL="./appimagetool-x86_64.AppImage"
if ! command -v appimagetool >/dev/null 2>&1; then
  if [ ! -f "${APPIMAGETOOL}" ]; then
    msg "Downloading appimagetool..."
    if command -v curl >/dev/null 2>&1; then
      curl -L -f -o "${APPIMAGETOOL}" "${APPIMAGETOOL_URL}"
    else
      wget -O "${APPIMAGETOOL}" "${APPIMAGETOOL_URL}"
    fi
    chmod +x "${APPIMAGETOOL}"
  fi
  APPIMAGETOOL_CMD="${APPIMAGETOOL}"
else
  APPIMAGETOOL_CMD="appimagetool"
fi

# 11) Build the AppImage
msg "Building AppImage (this may take a moment)..."
# appimagetool expects an AppDir folder, call it AppDir
"${APPIMAGETOOL_CMD}" "${APPDIR}" || { err "appimagetool failed"; exit 1; }

msg "Done. You should have a ${OUT_NAME}-<arch>.AppImage in the working directory."
