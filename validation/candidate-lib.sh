#!/usr/bin/env bash
# Acceptance boundaries shared by the real-host harness and rejection tests.
# This file is sourced; it changes neither shell options nor host state.

sb_candidate_manifest() {
    local directory="$1" expected="$2" actual name
    [[ "$expected" =~ ^[0-9a-f]{64}$ ]] || return 1
    [[ -f "$directory/SHA256SUMS" && ! -L "$directory/SHA256SUMS" ]] || return 1
    actual="$(sha256sum "$directory/SHA256SUMS")" || return 1
    [[ "${actual%% *}" == "$expected" ]] || return 1
    # Names must be local regular files, never paths, options or symlinks.
    awk 'length($1) != 64 || $1 ~ /[^0-9a-f]/ || NF != 2 ||
         $2 !~ /^[A-Za-z0-9][A-Za-z0-9._-]*$/ || seen[$2]++ {bad=1}
         END {exit bad || NR == 0}' "$directory/SHA256SUMS" || return 1
    while read -r actual name; do
        [[ -f "$directory/$name" && ! -L "$directory/$name" ]] || return 1
    done < "$directory/SHA256SUMS"
    (cd "$directory" && sha256sum --strict -c SHA256SUMS)
}

sb_startup_status() {
    [[ -f "$1" && ! -L "$1" ]] && cmp -s "$1" <(printf 'exit=0\n')
}

sb_startup_identity() {
    local block="$1" script="$2" approved_sha="${3:-}" actual
    [[ -s "$block" && -f "$script" && ! -L "$script" ]] || return 1
    if [[ -n "$approved_sha" ]]; then
        # Some providers prepend a Bash shebang. Review/hash those exact bytes
        # before boot. Other wrappers need their own reviewed verifier; merely
        # finding our payload inside a comment or heredoc proves nothing.
        [[ "$approved_sha" =~ ^[0-9a-f]{64}$ ]] || return 1
        actual="$(sha256sum "$script")" || return 1
        [[ "${actual%% *}" == "$approved_sha" ]] || return 1
        perl -0777 -e '
            sub read_all { open my $f, "<:raw", $_[0] or exit 2; local $/; <$f> }
            my ($block, $script) = map { read_all($_) } @ARGV;
            my $payload = $block . qq{echo "exit=\$?" > /root/sb-startup-status\n};
            exit($script eq $payload || $script eq "#!/bin/bash\n" . $payload ||
                 $script eq "#!/usr/bin/env bash\n" . $payload ? 0 : 1);
        ' "$block" "$script"
    else
        # Default: exact payload only. A commented copy, heredoc, early exit,
        # changed command or an extra command cannot pass as the startup script.
        cmp -s "$script" <(cat "$block"; printf '%s\n' 'echo "exit=$?" > /root/sb-startup-status')
    fi
}

sb_provider_history() {
    local history="$1" package_status="$2"
    [[ "$package_status" == 'install ok installed' ]] || return 1
    awk 'BEGIN {RS=""}
         /Commandline:[^\n]*install[^\n]*openssh-server/ {record=$0}
         END {exit !(record ~ /(^|\n)End-Date:/ && record !~ /(^|\n)Error:/)}' "$history"
}

sb_provider_transaction() {
    [[ "$3" == 0 ]] && sb_provider_history "$1" "$2"
}

sb_no_driver_changes() {
    # Read the full apt history, including rotated records. Only transaction
    # change fields count; incidental prose or a package simulation is not a change.
    awk '/^(Install|Upgrade|Downgrade|Reinstall|Remove|Purge):/ {
        sub(/^[^:]*: /, ""); n=split($0, packages, /, /)
        for (i=1; i<=n; i++) {
            package=packages[i]; sub(/[: (].*/, "", package)
            if (package ~ /^(nvidia|libnvidia|cuda|libcuda|cudnn|libcudnn|libnccl|libcublas|libcufft|libcurand|libcusolver|libcusparse|libnpp|libnvjpeg|libnvrtc|libnvjitlink|libcupti|libnvtoolsext|libcudart|nsight-)|-nvidia(-|$)/) bad=1
        }
    } END {exit bad}' "$1"
}

sb_nvidia_fingerprint() {
    nvidia-smi --query-gpu=uuid,driver_version --format=csv,noheader | LC_ALL=C sort || return 1
    dpkg-query -W -f='${binary:Package} ${Version} ${Status}\n' 2>/dev/null |
        awk '/^(nvidia|libnvidia|cuda|libcuda|cudnn|libcudnn|libnccl|libcublas|libcufft|libcurand|libcusolver|libcusparse|libnpp|libnvjpeg|libnvrtc|libnvjitlink|libcupti|libnvtoolsext|libcudart|nsight-)|^[^ ]*-nvidia(-|:| )/ && /install ok installed$/' |
        LC_ALL=C sort
}
