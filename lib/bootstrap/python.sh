#!/usr/bin/env bash

# Installs a launcher at $2 that execs "$1/bin/python" with the caller's
# arguments and exit status. $2 may already exist as a symlink (from an older
# release) or as a launcher from a prior run of this function; either way, a
# temporary file is written beside it and renamed into place so the pathname
# is never opened for writing while it still resolves into the venv, which
# would otherwise truncate the interpreter it points to.
bootstrap_install_base_python_launcher() {
    local venv="$1" target="$2" tmp
    tmp="$(mktemp "$(dirname -- "$target")/.$(basename -- "$target").XXXXXX")"
    cat > "$tmp" <<LAUNCHEOF
#!/usr/bin/env bash
exec "$venv/bin/python" "\$@"
LAUNCHEOF
    chmod 0755 "$tmp"
    mv -f "$tmp" "$target"
}

bootstrap_base_python() {
    NUMPY_VERSION="(not installed)"
    [[ "$INSTALL_BASE_PYTHON_ENV" == 1 ]] || return 0
    if command -v uv >/dev/null 2>&1; then
        [[ -x "$BASE_PYTHON_ENV/bin/python" ]] || uv venv "$BASE_PYTHON_ENV"
        # shellcheck disable=SC2086
        sb_retry 3 uv pip install --python "$BASE_PYTHON_ENV/bin/python" $BASE_PYTHON_PACKAGES
    else
        [[ -x "$BASE_PYTHON_ENV/bin/python" ]] || python3 -m venv "$BASE_PYTHON_ENV"
        # shellcheck disable=SC2086
        sb_retry 3 "$BASE_PYTHON_ENV/bin/python" -m pip install $BASE_PYTHON_PACKAGES
    fi
    bootstrap_install_base_python_launcher "$BASE_PYTHON_ENV" /usr/local/bin/base-python
    cat > /usr/local/bin/base-python-env <<PYEOF
#!/usr/bin/env bash
source "$BASE_PYTHON_ENV/bin/activate"
exec "\${SHELL:-/bin/bash}"
PYEOF
    chmod 0755 /usr/local/bin/base-python-env
    NUMPY_VERSION="$("$BASE_PYTHON_ENV/bin/python" -c 'import numpy; print(numpy.__version__)' 2>/dev/null || echo unknown)"
    sb_log "base Python environment ready (numpy $NUMPY_VERSION)"
}
