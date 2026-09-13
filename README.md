# projbox

`projbox.sh` creates a disposable, per-project Podman container for
building/testing your code against a different distro, toolchain, or set of
versions than what's installed on your host.

Each project gets its own container with:

- Your project directory mounted at `~/project` inside the container — that's
  the only thing shared with the host.
- A normal user account matching your own UID/GID, with passwordless `sudo`
  (if possible).
- Its own isolated home directory, seeded with the image's default dotfiles
  plus anything you've set up yourself.

## Usage

```
# Built-in help with all the details
projbox.sh help

# Create a container for the current directory ...
projbox.sh create TEMPLATE [CONTAINER_NAME]
# ... and enter it (auto-detected from the current directory if omitted)
projbox.sh enter  [CONTAINER_NAME]

# Shows know project and container mappings
projbox.sh list
# Remove given container
projbox.sh rm     CONTAINER_NAME
```

`TEMPLATE` is either the name of a container image (e.g. `fedora:44`), the
name of an existing container to clone, or the name of a *template* you've set
up under `~/.config/projbox/skel/`.

## Templates

A template is just a folder: `~/.config/projbox/skel/<name>/`, containing any of:

- `box.rc`: configuration of the template (image, packages to install, ...)
- `skel/`: files to be copied into the new container's home directory (such as
  dot files)
- `on_create.sh`: shell script hook that is executed once the container is
  created
- `host_hook.sh`: shell script that is executed on the HOST and that can further
  modify files that are to be copied into home in the container (useful for
  copying credentials files and other files from host)

### Example

```
~/.config/projbox/skel/fedora-dev/
├── box.rc
├── skel/
│   ├── .gitconfig
│   └── .bashrc
├── host_hook.sh
└── on_create.sh
```

```sh
# box.rc
image="fedora:44"
install="git vim mc"
```

```sh
# skel/.bashrc
alias ll='ls -l'
```

```sh
# on_create.sh
dnf copr enable ...
```

With this in place:

```
cd ~/projects/myapp
projbox.sh create fedora-dev
projbox.sh enter
```

...and you're in a fresh Fedora container, as yourself, with sudo,
your dotfiles, your usual packages, and `~/project` pointing at
`~/projects/myapp` (with read-write permissions).

