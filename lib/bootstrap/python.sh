#!/usr/bin/env bash

bootstrap_base_python() {
    NUMPY_VERSION="(not installed)"
    [[ "$INSTALL_BASE_PYTHON_ENV" == 1 ]] || return 0
    if command -v uv >/dev/null 2>&1; then
        [[ -x "$BASE_PYTHON_ENV/bin/python" ]] || uv venv "$BASE_PYTHON_ENV"
        # shellcheck disable=SC2086
        gsb_retry 3 uv pip install --python "$BASE_PYTHON_ENV/bin/python" $BASE_PYTHON_PACKAGES
    else
        [[ -x "$BASE_PYTHON_ENV/bin/python" ]] || python3 -m venv "$BASE_PYTHON_ENV"
        # shellcheck disable=SC2086
        gsb_retry 3 "$BASE_PYTHON_ENV/bin/python" -m pip install $BASE_PYTHON_PACKAGES
    fi
    ln -sf "$BASE_PYTHON_ENV/bin/python" /usr/local/bin/base-python
    cat > /usr/local/bin/base-python-env <<PYEOF
#!/usr/bin/env bash
source "$BASE_PYTHON_ENV/bin/activate"
exec "\${SHELL:-/bin/bash}"
PYEOF
    chmod 0755 /usr/local/bin/base-python-env
    NUMPY_VERSION="$("$BASE_PYTHON_ENV/bin/python" -c 'import numpy; print(numpy.__version__)' 2>/dev/null || echo unknown)"
    gsb_log "base Python environment ready (numpy $NUMPY_VERSION)"
}
