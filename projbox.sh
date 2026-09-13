#!/usr/bin/env bash
#
# projbox.sh - manage per-project podman containers
#
# Created by Claude AI, manually reviewed
#
set -euo pipefail

self_path="$(readlink -f "${BASH_SOURCE[0]}")"

PROJBOX_CONFIG_DIR="${PROJBOX_CONFIG_DIR:-${XDG_CONFIG_HOME:-$HOME/.config}/projbox}"
# Each subdirectory here is a template: <name>/box.rc (optional; a real
# shell script, sourced - only its "image" and "home" variables are
# read) and <name>/skel/ (optional, copied into the container's own
# filesystem, never bind-mounted from the host).
PROJBOX_SKEL_ROOT="${PROJBOX_SKEL_ROOT:-$PROJBOX_CONFIG_DIR/skel}"

PROJBOX_STATE_DIR="${PROJBOX_STATE_DIR:-${XDG_STATE_HOME:-$HOME/.local/state}/projbox}"
PROJBOX_MAP_FILE="$PROJBOX_STATE_DIR/mapping.tsv"

mkdir -p "$PROJBOX_SKEL_ROOT" "$PROJBOX_STATE_DIR"
touch "$PROJBOX_MAP_FILE"

die()  { echo "projbox: error: $*" >&2; exit 1; }
info() { echo "projbox: $*" >&2; }

sanitize_name() {
  # lower-case, replace anything not [a-z0-9-] with '-', trim leading/trailing '-'
  local s
  s="$(echo "$1" | tr '[:upper:]' '[:lower:]' | sed -E 's/[^a-z0-9-]+/-/g; s/^-+//; s/-+$//')"
  [[ -n "$s" ]] || s="project"
  echo "$s"
}

name_in_use() {
  local name="$1"
  grep -qP "^\Q${name}\E\t" "$PROJBOX_MAP_FILE" 2>/dev/null && return 0
  podman container exists "$name" && return 0
  return 1
}

generate_container_name() {
  local base suffix candidate
  base="$(sanitize_name "$(basename "$PWD")")"
  candidate="$base"
  suffix=2
  while name_in_use "$candidate"; do
    candidate="${base}-${suffix}"
    suffix=$((suffix + 1))
  done
  echo "$candidate"
}

# Sources box.rc ($1) in a subshell (so it can't leak variables or side
# effects into the caller) and prints its "image", "home", and "install"
# variables, tab-separated. Since it's a real sourced script, full shell
# quoting, escaping, command substitution, etc. all just work - no text
# parsing.
read_box_vars() {
  local file="$1"
  ( source "$file"; printf '%s\t%s\t%s\n' "${image-}" "${home-}" "${install-}" )
}

# Writes the generic, container-side setup script to path $1. It's
# fully static (a quoted heredoc - no interpolation, no \$ escaping
# needed anywhere) and reads its actual per-container config by sourcing
# ./setup.rc next to it, so the exact same setup.sh works for every
# container; only setup.rc differs. It best-effort creates a user
# matching setup.rc's uid/gid, gives it passwordless sudo, installs any
# packages listed in setup.rc's "packages", and fixes ownership of
# $home itself and everything in it except "project" (which needs no
# fixing under --userns=keep-id, since that UID already maps 1:1 to the
# real host owner). The chown is needed because useradd -m does NOT
# take ownership of a home directory that already exists (we pre-create
# it so podman cp has somewhere to copy skel/ into before this runs).
write_setup_sh() {
  cat > "$1" <<'SETUP_EOF'
#!/bin/sh
set -e

. /root/install/setup.rc

PKG=""
UPDATE=":"
if command -v apt-get >/dev/null 2>&1; then PKG="apt-get install -y"; UPDATE="apt-get update"
elif command -v dnf >/dev/null 2>&1; then PKG="dnf install -y"
elif command -v yum >/dev/null 2>&1; then PKG="yum install -y"
elif command -v pacman >/dev/null 2>&1; then PKG="pacman -Sy --noconfirm"
elif command -v apk >/dev/null 2>&1; then PKG="apk add"
fi

if ! command -v sudo >/dev/null 2>&1 && [ -n "$PKG" ]; then
  $UPDATE >/dev/null 2>&1 || true
  $PKG sudo >/dev/null 2>&1 || true
fi
if ! command -v useradd >/dev/null 2>&1 && [ -n "$PKG" ]; then
  $PKG shadow >/dev/null 2>&1 || $PKG shadow-utils >/dev/null 2>&1 || true
fi

getent group "$gid" >/dev/null 2>&1 || groupadd -g "$gid" "$username" >/dev/null 2>&1 || true
group_name="$(getent group "$gid" | cut -d: -f1)"

if ! id -u "$username" >/dev/null 2>&1; then
  useradd -u "$uid" -g "${group_name:-$gid}" -d "$home" -m -s /bin/bash "$username" >/dev/null 2>&1 \
    || useradd -u "$uid" -g "${group_name:-$gid}" -d "$home" -m -s /bin/sh "$username" >/dev/null 2>&1 \
    || echo "projbox: warning: could not create a matching user in the container" >&2
fi

if command -v sudo >/dev/null 2>&1; then
  { echo "$username ALL=(ALL) NOPASSWD:ALL" > "/etc/sudoers.d/$username"; chmod 0440 "/etc/sudoers.d/$username"; } 2>/dev/null || true
fi

if [ -n "$packages" ] && [ -n "$PKG" ]; then
  $UPDATE >/dev/null 2>&1 || true
  $PKG $packages >/dev/null 2>&1 || echo "projbox: warning: failed to install packages: $packages" >&2
fi

{ chown "$uid:$gid" "$home"; find "$home" -mindepth 1 -maxdepth 1 -not -name project -exec chown -R "$uid:$gid" {} +; } 2>/dev/null || true
SETUP_EOF
}

## Create a project-specific plain podman container for the current
## directory.
## Usage: create TEMPLATE_NAME [CONTAINER_NAME]
##
## TEMPLATE_NAME is looked up as $PROJBOX_SKEL_ROOT/TEMPLATE_NAME/:
##   box.rc - optional; a real shell script that gets sourced (so full
##            quoting/escaping/command substitution all just work, not
##            a parsed text format) - only its "image" (the container
##            image; required if box.rc exists), "home" (default
##            /home/USERNAME - the path used both for ~/project and
##            for the skel/ copy below), and "install" (a space-
##            separated package list, installed via whichever of
##            apt-get/dnf/yum/pacman/apk the image has - best effort)
##            variables are read afterward. Since it's sourced for
##            real, only put trusted content in a box.rc.
##   skel/  - optional; copied into the container's OWN filesystem via
##            `podman cp` before it starts, never bind-mounted from
##            the host, so nothing the container does to those files
##            touches your disk. Applied on top of the image's own
##            /etc/skel (so a default .bashrc/prompt/etc. is always
##            present even without a skel/ of your own), and symlinks
##            in skel/ are dereferenced first, so an entry can point
##            at a real dotfile elsewhere without leaking that host
##            path into the container.
##   on_create.sh - optional; copied in and run (as root, chmod +x'd)
##            right after the user/sudo setup below, with uid/gid/
##            username/home/packages already exported into its
##            environment (from setup.rc, see below).
##   host_hook.sh - optional; NOT copied into the container - run on
##            the HOST, as yourself, after skel/ is staged but before
##            it's pushed in, as:
##              host_hook.sh STAGING_DIR PROJECT_PATH CONTAINER_NAME USERNAME HOME
##            Free to add or overwrite files under STAGING_DIR (which
##            mirrors what will become $home) using real host context -
##            e.g. copying a host credentials file in for a tool that's
##            about to be installed via on_create.sh. Since it runs
##            unsandboxed on the host, only put trusted content in a
##            host_hook.sh.
##
## With no box.rc, TEMPLATE_NAME is used directly as the image.
##
## The current directory is bind-mounted at $home/project inside the
## container - that is the only thing shared with the host.
##
## The container is created with --userns=keep-id (rootless podman
## only) so your host UID maps to itself inside the container, and a
## matching user (username: your own, or $PROJBOX_USERNAME if set) is
## created with passwordless sudo - best effort, since it depends on
## the image having (or being able to install) useradd/sudo. Note:
## --userns=keep-id also changes what `podman exec` defaults to (the
## mapped non-root user, not root), so the setup steps that need real
## root explicitly pass --user root. `enter` uses the created user
## automatically if it exists, otherwise falls back to the image's
## default user.
##
## The setup script and its config are left in the container at
## /root/install/ (setup.sh, setup.rc, and on_create.sh if used) for
## later inspection or rerunning - copying them in and running them
## from there, rather than piping a one-off script through `sh -c`,
## costs nothing and makes the whole thing reproducible and debuggable.
action_create() {
  local template_name="${1:-}" container_name="${2:-}"
  [[ -n "$template_name" ]] || { action_help; die "TEMPLATE_NAME is required"; }

  local project_path
  project_path="$(pwd -P)"

  if [[ -z "$container_name" ]]; then
    container_name="$(generate_container_name)"
  else
    container_name="$(sanitize_name "$container_name")"
    name_in_use "$container_name" && die "container name '$container_name' is already in use"
  fi

  local template_dir="$PROJBOX_SKEL_ROOT/$template_name"
  local skel_dir="$template_dir/skel"
  local box_rc="$template_dir/box.rc"
  local on_create_src="$template_dir/on_create.sh"
  local host_hook_src="$template_dir/host_hook.sh"

  local username
  username="$(sanitize_name "${PROJBOX_USERNAME:-$(id -un)}")"

  local image home install
  if [[ -f "$box_rc" ]]; then
    info "using $box_rc"
    local box_vars rest
    box_vars="$(read_box_vars "$box_rc")" || die "failed to evaluate $box_rc"
    image="${box_vars%%$'\t'*}"
    rest="${box_vars#*$'\t'}"
    home="${rest%%$'\t'*}"
    install="${rest#*$'\t'}"
    [[ -n "$image" ]] || die "$box_rc did not set 'image'"
  else
    image="$template_name"
    install=""
  fi
  home="${home:-/home/$username}"

  # both staging dirs (whichever get used) are cleaned up together on return
  local skel_staging="" install_staging=""
  trap 'rm -rf "$skel_staging" "$install_staging"' RETURN

  info "creating container '$container_name' from image '$image'"
  podman create --name "$container_name" \
    --userns=keep-id \
    --volume "$project_path:$home/project" \
    "$image" \
    tail -f /dev/null >/dev/null

  podman start "$container_name" >/dev/null

  # the image may not have $home yet (it's not necessarily /root) - create
  # it before anything tries to write into it. --userns=keep-id makes
  # `podman exec` default to the mapped (non-root) user, so these setup
  # steps need an explicit --user root to actually get root inside the
  # container.
  podman exec --user root "$container_name" mkdir -p "$home"

  # pre-creating $home above means useradd -m won't populate it from
  # /etc/skel later (it only does that for a home dir it creates itself),
  # so seed it from the image's own /etc/skel first - a sane .bashrc/
  # .profile/prompt baseline - before the host's skel/ overlays on top.
  podman exec --user root "$container_name" \
    sh -c "[ -d /etc/skel ] && cp -a /etc/skel/. \"$home/\" 2>/dev/null; true"

  if [[ -d "$skel_dir" || -f "$host_hook_src" ]]; then
    skel_staging="$(mktemp -d)"
    if [[ -d "$skel_dir" ]]; then
      cp -aL "$skel_dir"/. "$skel_staging"/
    fi
    if [[ -f "$host_hook_src" ]]; then
      info "running host_hook.sh"
      bash "$host_hook_src" "$skel_staging" "$project_path" "$container_name" "$username" "$home" \
        || info "warning: host_hook.sh exited non-zero"
    fi
    if [[ -n "$(ls -A "$skel_staging" 2>/dev/null)" ]]; then
      info "copying skel into the container"
      podman cp "$skel_staging"/. "$container_name:$home/"
    fi
  fi

  info "setting up user '$username' with sudo (best effort)"
  local uid gid
  uid="$(id -u)"
  gid="$(id -g)"

  install_staging="$(mktemp -d)"
  write_setup_sh "$install_staging/setup.sh"
  cat > "$install_staging/setup.rc" <<RCEOF
export uid="$uid"
export gid="$gid"
export username="$username"
export home="$home"
export packages="$install"
RCEOF
  if [[ -f "$on_create_src" ]]; then
    cp "$on_create_src" "$install_staging/on_create.sh"
  fi

  podman exec --user root "$container_name" mkdir -p /root/install
  podman cp "$install_staging"/. "$container_name:/root/install/"

  podman exec --user root "$container_name" sh /root/install/setup.sh \
    || info "warning: user/sudo setup did not fully succeed; 'enter' will fall back to the image's default user"

  if [[ -f "$install_staging/on_create.sh" ]]; then
    info "running on_create.sh"
    podman exec --user root "$container_name" chmod +x /root/install/on_create.sh
    podman exec --user root "$container_name" sh -c '. /root/install/setup.rc; exec /root/install/on_create.sh' \
      || info "warning: on_create.sh exited non-zero"
  fi

  printf '%s\t%s\t%s\t%s\t%s\n' "$container_name" "$project_path" "$template_name" "$username" "$home" >> "$PROJBOX_MAP_FILE"
  info "done. project is available at $home/project inside the container."
  info "enter with: projbox.sh enter $container_name   (or just 'projbox.sh enter' from this directory)"
}

find_container_for_cwd() {
  local cwd best_match="" best_len=0 name path
  cwd="$(pwd -P)"
  while IFS=$'\t' read -r name path _; do
    [[ -z "$name" ]] && continue
    if [[ "$cwd" == "$path" || "$cwd" == "$path"/* ]]; then
      if [[ "${#path}" -gt "$best_len" ]]; then
        best_match="$name"
        best_len="${#path}"
      fi
    fi
  done < "$PROJBOX_MAP_FILE"
  echo "$best_match"
}

lookup_container_field() {
  local name="$1" field="$2"
  awk -F'\t' -v n="$name" -v f="$field" '$1==n{print $f; exit}' "$PROJBOX_MAP_FILE" 2>/dev/null
}

## Enter the container for the current directory, or CONTAINER_NAME
## if given. Uses the user created at `create` time (if it exists and
## has sudo), cd'd into ~/project; falls back to the image's default
## user otherwise. Tries bash first, falls back to sh for minimal
## images.
## Usage: enter [CONTAINER_NAME]
action_enter() {
  local container_name="${1:-}"
  if [[ -z "$container_name" ]]; then
    container_name="$(find_container_for_cwd)"
    [[ -n "$container_name" ]] || die "no known container for $(pwd -P); run 'projbox.sh create' here first, or pass a container name"
  fi

  local username home
  username="$(lookup_container_field "$container_name" 4)"
  home="$(lookup_container_field "$container_name" 5)"

  local exec_args=(-it)
  if [[ -n "$username" ]] && podman exec "$container_name" id -u "$username" >/dev/null 2>&1; then
    exec_args+=(--user "$username")
    if [[ -n "$home" ]]; then
      # --userns=keep-id starts the container as an unrecognized UID with
      # no passwd entry yet, so podman bakes in HOME=/ at container-start
      # time; that stale value isn't recomputed later even though the
      # user we created has the right passwd entry, so it has to be set
      # explicitly here.
      exec_args+=(--env "HOME=$home" --workdir "$home/project")
    fi
  else
    info "no matching in-container user found, entering as the image's default user"
  fi

  podman exec "${exec_args[@]}" "$container_name" bash 2>/dev/null \
    || podman exec "${exec_args[@]}" "$container_name" sh
}

## List known project <-> container mappings.
action_list() {
  if [[ ! -s "$PROJBOX_MAP_FILE" ]]; then
    info "no projects registered yet"
    return
  fi
  printf '%-25s %-15s %-12s %s\n' "CONTAINER" "TEMPLATE" "USER" "PROJECT PATH"
  while IFS=$'\t' read -r name path template username _; do
    printf '%-25s %-15s %-12s %s\n' "$name" "$template" "$username" "$path"
  done < "$PROJBOX_MAP_FILE"
}

## Remove a container (via podman) and its mapping entry.
## Usage: rm CONTAINER_NAME
action_rm() {
  local container_name="${1:-}"
  [[ -n "$container_name" ]] || die "usage: projbox.sh rm CONTAINER_NAME"
  podman rm -f "$container_name" || info "warning: podman rm failed (container may not exist)"
  if [[ -s "$PROJBOX_MAP_FILE" ]]; then
    grep -vP "^\Q${container_name}\E\t" "$PROJBOX_MAP_FILE" > "$PROJBOX_MAP_FILE.tmp" || true
    mv "$PROJBOX_MAP_FILE.tmp" "$PROJBOX_MAP_FILE"
  fi
}

get_self_commands() {
    sed -n -e 's#^[ ]*action_\([a-zA-Z_0-9]*\)()[ ]*{#\1#p' <"$self_path" | sort | while read -r command; do
        echo "$command" "$(
            grep -Pzo '[\n]([ ]*##( .*)?[\n])*action_'"$command"'[(]' <"$self_path" \
            | sed -n -e 's:^[ ]*## \(.*\):\1:p' -e 's:^[ ]*##[ ]*$::p' \
            | base64 -w0
        )"
    done
}

show_help() {
    echo "projbox.sh - manage per-project podman containers"
    echo
    echo "Usage: $(basename "$self_path") command"
    echo
    get_self_commands | sort | grep "${1:-}" | while read -r command description; do
        echo "$command" | tr '_' '-'
        echo "$description" | base64 -d | sed 's#.*#    &#'
        echo
    done
}

## List all available commands.
action_help() {
    show_help
}

# When run without parameters, print only commands with description.
action_briefhelp() {
    show_help '^[^ ]* ..*'
}

action="${1:-}"
if [ -z "$action" ]; then
    action="briefhelp"
else
    action="$( echo "$action" | tr '-' '_' )"
    shift
fi

if [ "$( type -t "action_$action" || true )" = "function" ]; then
    "action_$action" "$@"
else
    echo "Unknown action $action, use help to print available actions."
    exit 1
fi

