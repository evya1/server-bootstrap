#!/usr/bin/env bash

bootstrap_install_runtime_tools() {
    [[ "$INSTALL_RUNTIME_TOOLS" == 1 ]] || return 0
    local source_root="$1" destination=/usr/local/lib/gpu-server-bootstrap stage
    stage="$(mktemp -d /usr/local/lib/.gpu-server-bootstrap.XXXXXX)"
    mkdir -p "$stage/lib/bootstrap" "$stage/docs" "$stage/config"
    install -m 0755 "$source_root/gpu-server-bootstrap.sh" "$stage/gpu-server-bootstrap.sh"
    install -m 0755 "$source_root/gpu-bundle-install" "$stage/gpu-bundle-install"
    install -m 0755 "$source_root/gpu-provision.sh" "$stage/gpu-provision.sh"
    install -m 0755 "$source_root/gpu-accept.sh" "$stage/gpu-accept.sh"
    install -m 0755 "$source_root/gpu-vscode-extensions" "$stage/gpu-vscode-extensions"
    install -m 0644 "$source_root/lib/core.sh" "$stage/lib/core.sh"
    install -m 0644 "$source_root/lib/archive.sh" "$stage/lib/archive.sh"
    install -m 0644 "$source_root/lib/bundle.sh" "$stage/lib/bundle.sh"
    local module
    for module in "$source_root"/lib/bootstrap/*.sh; do
        install -m 0644 "$module" "$stage/lib/bootstrap/$(basename -- "$module")"
    done
    local doc
    for doc in "$source_root"/docs/*.md; do
        install -m 0644 "$doc" "$stage/docs/$(basename -- "$doc")"
    done
    install -m 0644 "$source_root/README.md" "$stage/README.md"
    install -m 0644 "$source_root/VERSION" "$stage/VERSION"
    install -m 0644 "$source_root/config/vscode-extensions.txt" "$stage/config/vscode-extensions.txt"
    rm -rf -- "$destination"
    mv -- "$stage" "$destination"
    ln -sfn "$destination/gpu-server-bootstrap.sh" /usr/local/bin/gpu-server-bootstrap
    ln -sfn "$destination/gpu-bundle-install" /usr/local/bin/gpu-bundle-install
    ln -sfn "$destination/gpu-provision.sh" /usr/local/bin/gpu-provision
    ln -sfn "$destination/gpu-accept.sh" /usr/local/bin/gpu-accept
    ln -sfn "$destination/gpu-accept.sh" /usr/local/bin/gpu-accept.sh
    ln -sfn "$destination/gpu-vscode-extensions" /usr/local/bin/gpu-vscode-extensions
    gsb_log "installed bootstrap runtime tools under $destination"
}
