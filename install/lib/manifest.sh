#!/usr/bin/env bash
#
# Reading <app>/manifest.yaml — what an app needs, in the app's own words.
#
# The problem this exists to end: an app's required configuration used to be
# described in four places, none of them machine-readable. Which keys it needs was a
# comment in secrets.example.yaml. Which of them are generated was inferred from
# placeholder *text* in deploy/status.sh. Which are secret was inferred from the key's
# *suffix*. And which prefix it reads was a string default in install.sh with a
# per-app special case — `if [ "$APP" = "amber" ]` — that was correct for the one app
# that existed and wrong for the next one.
#
# The prefix is the sharpest of those, because getting it wrong fails silently. Both
# Amber's and Bloom's Settings classes use `extra="ignore"`, so a key under the wrong
# prefix is not an error, it is simply never read: the app starts, serves, never
# mounts its MCP server and never registers, and the only symptom is the word
# "unregistered" in a status report days later.
#
# So the manifest is authoritative for the prefix, and `manifest_lint` asserts that
# the three derived keys are spelled `${env_prefix}_PUBLIC_URL` / `_SYNC_STORE_URL` /
# `_SYNC_STORE_TOKEN`. Once that holds, the prefix and the key names *cannot*
# disagree, because the two are compared on every push.
#
# Key names are written out literally rather than composed from a prefix plus a
# suffix. Amber's own keys are AMBER_* while her agent-mcp keys are AMBER_MCP_*, so
# composition would need two prefix fields and would be the more fragile design. A
# literal name plus one equality check buys the same guarantee, and keeps the manifest
# diffable against secrets.example.yaml by eye.
#
# Source it, don't execute it.

# shellcheck source-path=SCRIPTDIR

[ -n "${_AMBER_INFRA_MANIFEST:-}" ] && return 0
_AMBER_INFRA_MANIFEST=1

# shellcheck source=common.sh
. "$(dirname "${BASH_SOURCE[0]}")/common.sh"

#: The manifest schema this code understands. A manifest declaring a higher number is
#: read anyway but warned about — every field so far is additive, and refusing to
#: install because a checkout is newer than a helper would be worse than the mismatch.
MANIFEST_VERSION=1

# --- reading -----------------------------------------------------------------
#
# Each manifest is read exactly ONCE, into tab-separated rows held in a variable, and
# every accessor below is a text lookup over that. Two reasons, both learned the hard
# way while writing this file:
#
#  * `yq -r '… // "default"'` cannot express "absent", because yq's `//`, like jq's,
#    treats an explicit `false` as empty. `required: false` came back as `true`, which
#    silently made every optional key mandatory. The raw value distinguishes them:
#    absent is the string `null`, false is `false`.
#  * `yq … | grep -q` is a trap under `set -o pipefail`. `grep -q` exits at the first
#    match, yq dies on the closed pipe, the pipeline reports failure, and the caller
#    concludes the key was *missing* — the exact opposite of what happened.
#
# Reading once also turns ~100 process spawns per app into one.

#: name, kind, required, secret, credential, source, group, label, default, help_url
_MANIFEST_ROW_EXPR='.keys[]? | [.name, .kind, .required, .secret, .credential, .source, .group, .label, .default, .help_url] | @tsv'
#: manifest, app, env_prefix, role, release.repo, release.package
_MANIFEST_HEAD_EXPR='[.manifest, .app, .env_prefix, .role, .release.repo, .release.package] | @tsv'

_manifest_rows_app=""; _manifest_rows=""
_manifest_head_app=""; _manifest_head=""

manifest_path() {  # manifest_path APP -> path, or empty when there is none
  local path="$REPO_ROOT/$1/manifest.yaml"
  [ -n "$1" ] && [ -f "$path" ] && echo "$path"
  return 0
}

manifest_have() {  # manifest_have APP -> 0 when this app declares one
  [ -n "$(manifest_path "$1")" ]
}

#: `null` is yq's word for "this field is absent". Nothing downstream wants to think
#: about that, so it is turned into the empty string exactly once, here.
_manifest_nn() { case "$1" in null|'') echo "" ;; *) echo "$1" ;; esac; }

manifest_rows() {  # manifest_rows APP -> one TSV row per declared key
  local path
  if [ "$_manifest_rows_app" != "$1" ]; then
    _manifest_rows_app="$1"; _manifest_rows=""
    path="$(manifest_path "$1")"
    if [ -n "$path" ]; then
      have yq || die "yq (v4) is required to read $path"
      _manifest_rows="$(yq -r "$_MANIFEST_ROW_EXPR" "$path" 2>/dev/null || true)"
    fi
  fi
  [ -n "$_manifest_rows" ] && printf '%s\n' "$_manifest_rows"
  return 0
}

_manifest_head() {  # _manifest_head APP FIELD_INDEX
  local path
  if [ "$_manifest_head_app" != "$1" ]; then
    _manifest_head_app="$1"; _manifest_head=""
    path="$(manifest_path "$1")"
    if [ -n "$path" ]; then
      have yq || die "yq (v4) is required to read $path"
      _manifest_head="$(yq -r "$_MANIFEST_HEAD_EXPR" "$path" 2>/dev/null || true)"
    fi
  fi
  _manifest_nn "$(awk -F'\t' -v n="$2" 'NR==1 {print $n}' <<<"$_manifest_head")"
}

manifest_version()  { local v; v="$(_manifest_head "$1" 1)"; echo "${v:-0}"; }
manifest_app()      { _manifest_head "$1" 2; }
#: Without the trailing underscore, always — install.sh appends its own.
manifest_env_prefix() { local p; p="$(_manifest_head "$1" 3)"; echo "${p%_}"; }
manifest_role()     { _manifest_head "$1" 4; }
manifest_repo()     { _manifest_head "$1" 5; }
manifest_package()  { _manifest_head "$1" 6; }

manifest_key_names() {  # manifest_key_names APP
  manifest_rows "$1" | cut -f1
}

manifest_has_key() {  # manifest_has_key APP KEY
  # awk rather than `grep -q`, deliberately: it consumes all of its input, so there is
  # no closed pipe and no spurious pipeline failure. See the note above.
  manifest_rows "$1" | awk -F'\t' -v k="$2" '$1 == k { found = 1 } END { exit !found }'
}

_manifest_field() {  # _manifest_field APP KEY FIELD_INDEX
  _manifest_nn "$(manifest_rows "$1" | awk -F'\t' -v k="$2" -v n="$3" '$1 == k { print $n; exit }')"
}

manifest_kind()       { _manifest_field "$1" "$2" 2; }
manifest_credential() { _manifest_field "$1" "$2" 5; }
manifest_source()     { _manifest_field "$1" "$2" 6; }
manifest_group()      { _manifest_field "$1" "$2" 7; }
manifest_default()    { _manifest_field "$1" "$2" 9; }
manifest_help_url()   { _manifest_field "$1" "$2" 10; }

#: Falls back to the key's own name so an error message always has something to say.
manifest_label() { local l; l="$(_manifest_field "$1" "$2" 8)"; echo "${l:-$2}"; }

#: `required` defaults to true: forgetting it should cost a refusal to install, not an
#: app that starts without a key it needs.
manifest_is_required() {  # manifest_is_required APP KEY
  [ "$(_manifest_field "$1" "$2" 3)" != "false" ]
}

#: Whether a value is a secret. The manifest may only RAISE this — a name ending in a
#: sensitive suffix is secret whatever the manifest claims, so a careless manifest can
#: never talk status.sh into printing a token.
manifest_is_secret() {  # manifest_is_secret APP KEY
  case "$2" in *_KEY|*_KEYS|*_TOKEN|*_SECRET|*_PASSWORD|*_PASS) return 0 ;; esac
  [ "$(_manifest_field "$1" "$2" 4)" = "true" ]
}

manifest_names_of_kind() {  # manifest_names_of_kind APP EXTENDED_REGEX
  manifest_rows "$1" | awk -F'\t' -v re="$2" '$2 ~ re { print $1 }'
}

#: The `peers` list on a `generated:token` key — the callers this app expects to hear
#: from, which become the `name:` halves of its compound bearer list. A list rather
#: than a scalar, so it is the one field that cannot live in the flat row above; read
#: on demand, which is rare enough not to matter.
manifest_peers() {  # manifest_peers APP KEY -> one peer name per line
  local path
  path="$(manifest_path "$1")"
  [ -n "$path" ] || return 0
  yq -r ".keys[]? | select(.name == \"$2\") | .peers[]?" "$path" 2>/dev/null || true
}

#: The other half of a `peer_token`: which app holds the matching value, and under
#: which key. Amber's AMBER_MCP_PEER_TOKEN must equal the token inside Bloom's
#: BLOOM_MCP_KEYS, and a mismatch is a 401 on every delegated task with nothing
#: anywhere saying so — which is why the pairing is declared rather than remembered.
manifest_peer_of()  { _manifest_side "$1" "$2" peer_of; }
manifest_peer_key() { _manifest_side "$1" "$2" peer_key; }

_manifest_side() {  # _manifest_side APP KEY FIELD
  local path value
  path="$(manifest_path "$1")"
  [ -n "$path" ] || return 0
  value="$(yq -r ".keys[]? | select(.name == \"$2\") | .$3" "$path" 2>/dev/null || true)"
  _manifest_nn "$value"
}

# --- the check that replaces the prefix guard --------------------------------
#
# Called from install.sh's preflight block, BEFORE anything has been written. The
# guard this replaces ran after ensure_caddy and secrets_render_env had already
# mutated the box, which violated this repo's own die-before-mutation rule — and it
# only tested `grep -q "^${PREFIX}_"`, so a stanza holding both AGENT_MCP_KEYS and
# BLOOM_MCP_KEYS passed while still half broken, and an empty env block passed
# trivially.
manifest_check() {  # manifest_check APP SECRETS_FILE
  local app="$1" secrets="$2" prefix declared name kind value version d orphan_fatal=0
  manifest_have "$app" || return 0

  version="$(manifest_version "$app")"
  if [ "${version:-0}" -gt "$MANIFEST_VERSION" ] 2>/dev/null; then
    warn "$app/manifest.yaml declares version $version; this checkout understands $MANIFEST_VERSION"
  fi

  prefix="$(manifest_env_prefix "$app")"
  [ -n "$prefix" ] || die "$app/manifest.yaml has no env_prefix"

  # The prefix and the derived key names must agree. manifest_lint asserts this in CI
  # too, but a box can be running a checkout older than the CI job, and this is the
  # assertion the whole design rests on — cheap enough to make twice.
  for d in PUBLIC_URL SYNC_STORE_URL SYNC_STORE_TOKEN; do
    manifest_has_key "$app" "${prefix}_${d}" || die \
      "$app/manifest.yaml declares env_prefix '$prefix' but not ${prefix}_${d}.
     The three derived keys are what the prefix *means*. If they disagree, the app
     reads one namespace while install.sh writes another, and nothing says so."
  done

  declared="$(yq -r ".apps.\"$app\".env // {} | keys | .[]" "$secrets" 2>/dev/null || true)"

  # 1. Everything required must be present, unless the installer supplies it.
  while IFS= read -r name; do
    [ -z "$name" ] && continue
    manifest_is_required "$app" "$name" || continue
    kind="$(manifest_kind "$app" "$name")"
    case "$kind" in derived|generated:*) continue ;; esac
    grep -qxF "$name" <<<"$declared" || die "'$app' is missing a required key: $name
     $(manifest_label "$app" "$name")
     Add it under apps.$app.env in $secrets, or run
     install/declare.sh --app $app --reconcile."
  done < <(manifest_key_names "$app")

  # 2. Anything declared that the manifest does not know about. A hand-added extra is
  #    legitimate, so this warns — EXCEPT when the orphan is a manifest key wearing
  #    the wrong prefix, which is the exact shape of the bug this file exists for.
  local suffix match
  while IFS= read -r name; do
    [ -z "$name" ] && continue
    manifest_has_key "$app" "$name" && continue
    suffix="${name#*_}"
    match=""
    [ "$suffix" != "$name" ] && match="$(manifest_key_names "$app" | grep -E "_${suffix}\$" | head -n1 || true)"
    if [ -n "$match" ]; then
      warn "$app declares $name, but this app reads $match"
      orphan_fatal=1
    else
      warn "$app declares $name, which $app/manifest.yaml does not mention"
    fi
  done <<<"$declared"

  [ "$orphan_fatal" = "0" ] || die "'$app' has keys under a prefix it does not read.
     Keys in another namespace are not an error to the app — they are ignored. It
     would start, serve, never mount its MCP server and never register, with nothing
     saying why. Fix apps.$app in $secrets (install/declare.sh --app $app --reconcile
     --adopt renames them, keeping their values), then re-run this."

  # 3. No required key may still be a placeholder. secrets_render_env copies values
  #    verbatim with no placeholder check, so without this the word CHANGEME is
  #    rendered into the app's .env and mounted as a live bearer token on a public
  #    HTTPS endpoint. The one assertion here that is not about prefixes.
  while IFS= read -r name; do
    [ -z "$name" ] && continue
    manifest_is_required "$app" "$name" || continue
    kind="$(manifest_kind "$app" "$name")"
    [ "$kind" = "derived" ] && continue
    value="$(yq -r ".apps.\"$app\".env.\"$name\" // \"\"" "$secrets" 2>/dev/null || true)"
    case "$value" in
      *CHANGEME*)
        case "$kind" in
          generated:*) die "'$app' still has a placeholder in $name.
     $(manifest_label "$app" "$name")
     Run install/fill-secrets.sh --app $app to generate it." ;;
          *) die "'$app' still has a placeholder in $name.
     $(manifest_label "$app" "$name")
     This one needs a value only you have: $(manifest_help_url "$app" "$name")" ;;
        esac ;;
    esac
  done < <(manifest_key_names "$app")

  ok "$app/manifest.yaml: ${prefix}_* — $(manifest_key_names "$app" | grep -c . || true) keys declared"
}

# --- the static checks CI runs -----------------------------------------------
#
# These live here rather than in a workflow file because everything that knows the
# manifest format should be one thing you can read top to bottom. They need no box, no
# secrets file and no Docker — just yq and the checkout — so they also run locally:
#
#   bash -c '. install/lib/manifest.sh && manifest_lint_all'
#
# Check 3 is the one that matters. The rest are hygiene; check 3 is what turns "we
# remembered to set env_prefix correctly" into a property the repo cannot lose.

#: Mirrors deploy/status.sh's INFRA_SERVICES. Duplicated deliberately, like env_set:
#: two definitions with one comment beats a source-order dependency between a
#: read-only reporter and an install-time library.
MANIFEST_INFRA_SERVICES="caddy sync-store"

#: Every kind install.sh, fill-secrets.sh and the GUI know how to act on. A kind not on
#: this list is a manifest that means something no code implements.
_MANIFEST_KINDS='^(generated:(openssl-hex-32|fernet|token)|supplied|derived|config|peer_map|peer_token)$'

_lint_fails=0
_lint_fail() { echo "${c_red}error:${c_off} $*" >&2; _lint_fails=$((_lint_fails + 1)); }

manifest_lint() {  # manifest_lint APP
  local app="$1" path prefix version name kind cred src suffix got count example declared

  path="$(manifest_path "$app")"
  [ -n "$path" ] || { _lint_fail "$app has a docker-compose.prod.yml but no manifest.yaml"; return 0; }

  # 2. well-formed
  yq -e '.' "$path" >/dev/null 2>&1 || { _lint_fail "$app/manifest.yaml is not valid YAML"; return 0; }
  version="$(manifest_version "$app")"
  [ "$version" = "1" ] || _lint_fail "$app/manifest.yaml: manifest must be 1, got '$version'"
  [ "$(manifest_app "$app")" = "$app" ] \
    || _lint_fail "$app/manifest.yaml: 'app' must equal the directory name"
  prefix="$(manifest_env_prefix "$app")"
  grep -qE '^[A-Z][A-Z0-9_]*[A-Z0-9]$' <<<"$prefix" \
    || _lint_fail "$app/manifest.yaml: env_prefix '$prefix' is not an env-var prefix"

  # 3. THE assertion: the prefix and the derived key names cannot disagree.
  for src in public_url:PUBLIC_URL sync_store_url:SYNC_STORE_URL sync_store_token:SYNC_STORE_TOKEN; do
    suffix="${src##*:}"
    got="$(manifest_rows "$app" | awk -F'\t' -v s="${src%%:*}" '$6 == s { print $1 }')"
    count="$(grep -c . <<<"$got" || true)"
    # An explicit `if`, not `A && B || C`: that form runs C whenever the *chain* is
    # false, which happens to be what is wanted here and is not what it looks like.
    # Spelling it out costs one line and stops the next reader having to work that out.
    if [ -z "$got" ] || [ "$count" != "1" ]; then
      # `$got` is newline-separated, so printing it raw showed only the first name and
      # read as though the right key HAD been found. Say how many, and name them all.
      _lint_fail "$app/manifest.yaml: expected exactly one key with source '${src%%:*}', found $(
        if [ -z "$got" ]; then echo none; else echo "$count: $(tr '\n' ' ' <<<"$got")"; fi
      )"
      continue
    fi
    [ "$got" = "${prefix}_${suffix}" ] || _lint_fail \
      "$app/manifest.yaml: source '${src%%:*}' is declared as '$got', but env_prefix is '$prefix' so it must be '${prefix}_${suffix}'"
  done

  while IFS= read -r name; do
    [ -z "$name" ] && continue

    # 4. known kinds
    kind="$(manifest_kind "$app" "$name")"
    grep -qE "$_MANIFEST_KINDS" <<<"$kind" \
      || _lint_fail "$app/manifest.yaml: $name has unknown kind '$kind'"

    # 5. the secrecy floor, both directions
    case "$name" in
      *_KEY|*_KEYS|*_TOKEN|*_SECRET|*_PASSWORD|*_PASS)
        [ "$(_manifest_field "$app" "$name" 4)" = "false" ] && _lint_fail \
          "$app/manifest.yaml: $name declares secret:false, but its name says otherwise — status.sh would print it"
        ;;
    esac
    if manifest_is_secret "$app" "$name" && [ -n "$(manifest_default "$app" "$name")" ]; then
      _lint_fail "$app/manifest.yaml: $name is secret and carries a default, which status.sh would emit"
    fi

    # 7. credential id hygiene
    cred="$(manifest_credential "$app" "$name")"
    if [ -n "$cred" ]; then
      grep -qE '^[a-z][a-z0-9-]*$' <<<"$cred" \
        || _lint_fail "$app/manifest.yaml: credential '$cred' must be lower-kebab-case"
      [ "$kind" = "supplied" ] || _lint_fail \
        "$app/manifest.yaml: $name names a credential but its kind is '$kind' — only 'supplied' is filled from the vault"
    elif [ "$kind" = "supplied" ]; then
      _lint_fail "$app/manifest.yaml: $name is supplied but names no credential, so nothing can fill it"
    fi
  done < <(manifest_key_names "$app")

  # 6. the manifest and the example must describe the same app.
  example="$REPO_ROOT/secrets/secrets.example.yaml"
  [ -f "$example" ] || return 0
  yq -e ".apps.\"$app\"" "$example" >/dev/null 2>&1 || return 0

  got="$(yq -r ".apps.\"$app\".env_prefix // \"\"" "$example")"
  [ -z "$got" ] || [ "${got%_}" = "$prefix" ] \
    || _lint_fail "secrets.example.yaml: apps.$app.env_prefix is '$got' but the manifest says '$prefix'"

  declared="$(yq -r ".apps.\"$app\".env // {} | keys | .[]" "$example")"

  while IFS= read -r name; do
    [ -z "$name" ] && continue
    manifest_has_key "$app" "$name" \
      || _lint_fail "secrets.example.yaml: apps.$app.env.$name is not declared in $app/manifest.yaml"
  done <<<"$declared"

  while IFS= read -r name; do
    [ -z "$name" ] && continue
    manifest_is_required "$app" "$name" || continue
    # Derived keys are absent from the example on purpose: install.sh overwrites them,
    # so a placeholder there reads as an outstanding task that nobody can do.
    [ "$(manifest_kind "$app" "$name")" = "derived" ] && continue
    grep -qxF "$name" <<<"$declared" \
      || _lint_fail "secrets.example.yaml: apps.$app.env is missing required key $name"
  done < <(manifest_key_names "$app")
}

manifest_lint_all() {
  local f app cred label seen=""
  have yq || die "yq (v4) is required"
  _lint_fails=0

  # 1. the bijection, both directions. A manifest with nothing to install is one
  #    nobody will ever notice has gone stale.
  for f in "$REPO_ROOT"/*/docker-compose.prod.yml; do
    [ -f "$f" ] || continue
    app="$(basename "$(dirname "$f")")"
    case " $MANIFEST_INFRA_SERVICES " in *" $app "*) continue ;; esac
    manifest_lint "$app"
  done
  for f in "$REPO_ROOT"/*/manifest.yaml; do
    [ -f "$f" ] || continue
    app="$(basename "$(dirname "$f")")"
    [ -f "$REPO_ROOT/$app/docker-compose.prod.yml" ] \
      || _lint_fail "$app/manifest.yaml has no docker-compose.prod.yml beside it"
  done

  # 8. Two apps disagreeing about what one credential is called makes the vault's
  #    picker ambiguous — you would be asked which "OpenRouter key" you meant, twice,
  #    by two names.
  while IFS=$'\t' read -r cred label; do
    [ -z "$cred" ] && continue
    case "$seen" in
      *"|$cred=$label|"*) continue ;;
      *"|$cred="*) _lint_fail "credential '$cred' is labelled two different ways; pick one" ;;
    esac
    seen="$seen|$cred=$label|"
  done < <(
    for f in "$REPO_ROOT"/*/manifest.yaml; do
      [ -f "$f" ] || continue
      yq -r '.keys[]? | select(.credential) | [.credential, .label] | @tsv' "$f"
    done
  )

  [ "$_lint_fails" -eq 0 ] || die "$_lint_fails manifest problem(s)"
  ok "manifests are consistent"
}
