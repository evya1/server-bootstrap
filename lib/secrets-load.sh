#!/bin/sh
# API-key loading for interactive shells and for server-secrets.
#
# Written in POSIX shell on purpose: the generated Zsh startup file, the Bash
# server-secrets command, and the Bash test suite all use this one copy, so the
# parsing rules cannot drift between them.
#
# The keys file is PARSED, never sourced. A backtick or $(...) in a pasted
# value is data, not code.
#
# shellcheck disable=SC3043
# 'local' is outside POSIX, but Bash, Zsh and dash all implement it and those
# are the only shells that ever source this file. Dropping it would leak the
# parser's temporaries into the interactive shell that loads the keys.

SERVER_SECRETS_DEFAULT_FILE=/root/.config/server-bootstrap/secrets.env

server_secrets_path() {
    printf '%s\n' "${SERVER_SECRETS_FILE:-$SERVER_SECRETS_DEFAULT_FILE}"
}

# Names are tracked space-separated, and every loop over them uses parameter
# expansion rather than word splitting, which Zsh does not do by default.
server_secrets_each() {
    local rest name
    rest="$2"
    while [ -n "$rest" ]; do
        name="${rest%% *}"
        rest="${rest#"$name"}"
        rest="${rest# }"
        [ -n "$name" ] || continue
        "$1" "$name"
    done
}

server_secrets_mask() {
    local value length
    value="$1"
    [ -n "$value" ] || { printf '\n'; return 0; }
    length="$(printf '%s' "$value" | wc -c | tr -d ' ')"
    if [ "$length" -le 12 ]; then
        printf '********\n'
    else
        printf '%s...%s\n' \
            "$(printf '%s' "$value" | cut -c1-7)" \
            "$(printf '%s' "$value" | cut -c"$((length - 3))"-)"
    fi
}

# Reads KEY=VALUE lines and exports them. Everything else is skipped with a
# warning rather than silently ignored, so a typo is visible at login.
# With SERVER_SECRETS_EMIT=1 it also writes "name<TAB>value" to stdout, which
# is how status inspects the file without trusting the ambient environment.
server_secrets_load() {
    local file line name value loaded mode cr tab
    file="${1:-$(server_secrets_path)}"
    [ -r "$file" ] || return 0
    cr="$(printf '\r')"
    tab="$(printf '\t')"

    mode="$(stat -c '%a' "$file" 2>/dev/null || echo unknown)"
    case "$mode" in
        600|unknown) : ;;
        *) printf 'server-secrets: %s is mode %s; expected 600\n' "$file" "$mode" >&2 ;;
    esac

    loaded=""
    while IFS= read -r line || [ -n "$line" ]; do
        line="${line%"$cr"}"
        while :; do
            case "$line" in
                " "*|"$tab"*) line="${line#?}" ;;
                *) break ;;
            esac
        done
        case "$line" in
            ''|'#'*) continue ;;
            'export '*) line="${line#export }" ;;
        esac
        case "$line" in
            *=*) : ;;
            *) printf 'server-secrets: ignoring line without "=": %s\n' "$line" >&2; continue ;;
        esac

        name="${line%%=*}"
        value="${line#*=}"
        case "$name" in
            [A-Za-z_]*) : ;;
            *) printf 'server-secrets: ignoring invalid name: %s\n' "$name" >&2; continue ;;
        esac
        case "$name" in
            *[!A-Za-z0-9_]*)
                printf 'server-secrets: ignoring invalid name: %s\n' "$name" >&2
                continue ;;
        esac

        while :; do
            case "$value" in
                *" "|*"$tab") value="${value%?}" ;;
                *) break ;;
            esac
        done
        case "$value" in
            \"*\") value="${value#\"}"; value="${value%\"}" ;;
            \'*\') value="${value#\'}"; value="${value%\'}" ;;
        esac

        # An untouched placeholder must not export an empty string: Claude Code
        # and Codex treat a set-but-empty key as a configured credential.
        [ -n "$value" ] || continue

        if [ "${SERVER_SECRETS_EMIT:-0}" = 1 ]; then
            printf '%s\t%s\n' "$name" "$value"
        fi
        export "$name=$value"
        loaded="$loaded $name"
    done < "$file"

    SERVER_SECRETS_LOADED="${loaded# }"
    export SERVER_SECRETS_LOADED
    return 0
}

server_secrets_unload() {
    server_secrets_each unset "${SERVER_SECRETS_LOADED:-}"
    SERVER_SECRETS_LOADED=""
    export SERVER_SECRETS_LOADED
}

# Every name the file mentions, active or commented, so status can show what is
# still waiting to be filled in.
server_secrets_known_names() {
    local file
    file="${1:-$(server_secrets_path)}"
    [ -r "$file" ] || return 0
    sed -n 's/^[[:space:]]*#\{0,1\}[[:space:]]*\(export[[:space:]]\{1,\}\)\{0,1\}\([A-Za-z_][A-Za-z0-9_]*\)=.*/\2/p' \
        "$file" | awk '!seen[$0]++'
}

# Reports what the FILE defines. Deliberately not what the environment holds:
# an ambient GITHUB_TOKEN from some other source is not this file's business,
# and printing it here would leak an unrelated credential.
server_secrets_status() {
    local file pairs name value
    file="${1:-$(server_secrets_path)}"
    printf 'Keys file: %s' "$file"
    if [ -r "$file" ]; then
        printf ' (mode %s)\n\n' "$(stat -c '%a' "$file" 2>/dev/null || echo unknown)"
    else
        printf ' (not readable; run "server-secrets init")\n\n'
        return 0
    fi

    pairs="$( SERVER_SECRETS_EMIT=1; server_secrets_load "$file" 2>/dev/null )"
    server_secrets_known_names "$file" | while IFS= read -r name; do
        [ -n "$name" ] || continue
        value="$(printf '%s\n' "$pairs" | awk -F'\t' -v n="$name" '$1 == n { print $2; exit }')"
        if [ -n "$value" ]; then
            printf '  %-24s set      %s\n' "$name" "$(server_secrets_mask "$value")"
        else
            printf '  %-24s MISSING\n' "$name"
        fi
    done
    printf '\n'
}
