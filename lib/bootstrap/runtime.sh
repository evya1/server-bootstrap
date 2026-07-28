#!/usr/bin/env bash

bootstrap_install_runtime_tools() {
    [[ "$INSTALL_RUNTIME_TOOLS" == 1 ]] || return 0
    local source_root="$1" destination=/usr/local/lib/server-bootstrap stage
    stage="$(mktemp -d /usr/local/lib/.server-bootstrap.XXXXXX)"
    mkdir -p "$stage/lib/bootstrap" "$stage/docs" "$stage/config"
    install -m 0755 "$source_root/server-bootstrap.sh" "$stage/server-bootstrap.sh"
    install -m 0755 "$source_root/server-bundle-install" "$stage/server-bundle-install"
    install -m 0755 "$source_root/server-provision.sh" "$stage/server-provision.sh"
    install -m 0755 "$source_root/server-accept.sh" "$stage/server-accept.sh"
    install -m 0755 "$source_root/server-vscode-extensions" "$stage/server-vscode-extensions"
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
    install -m 0644 "$source_root/config/packages.txt" "$stage/config/packages.txt"
    rm -rf -- "$destination"
    mv -- "$stage" "$destination"
    ln -sfn "$destination/server-bootstrap.sh" /usr/local/bin/server-bootstrap
    ln -sfn "$destination/server-bundle-install" /usr/local/bin/server-bundle-install
    ln -sfn "$destination/server-provision.sh" /usr/local/bin/server-provision
    ln -sfn "$destination/server-accept.sh" /usr/local/bin/server-accept
    ln -sfn "$destination/server-accept.sh" /usr/local/bin/server-accept.sh
    ln -sfn "$destination/server-vscode-extensions" /usr/local/bin/server-vscode-extensions
    sb_log "installed bootstrap runtime tools under $destination"
}
