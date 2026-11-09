# Developer environments

`uvm` runs Linux tools in isolated Ubuntu ARM64 environments while macOS keeps
the editor, browser and terminal. It reuses UbuntuVM's accelerated QEMU,
Vulkan/OpenCL drivers and free-page reporting. No Docker Desktop is required.
The desktop is optional; development environments normally boot without GNOME.

## GUI controls

Open **Developer & SSH** in the sidebar of any Ubuntu VM. **Configure…** shows
its private SSH command, additional authorized public keys, LAN SSH publication,
and explicit TCP forwarding rules. Stop the VM before saving; settings apply
at its next start. Paste the other device's public `.pub` key, never a private key.
Existing guest keys and management SSH remain intact.

For LAN access, enable **Allow SSH from other devices**, choose a unique LAN
port for each VM, and copy the displayed command using your Mac's LAN address.
For example, two VMs can publish SSH on ports 2222 and 2223. This is NAT port
publication: each VM is a separate Linux system, but does not obtain its own
router-assigned LAN IP. The Mac firewall and network must allow the connection.
TCP forwards have separate Mac/guest ports and a **LAN** toggle. Unchecked rules
and automatic developer-port discovery bind only to localhost. Turn off the
experimental Fast network before using this NAT publication.

**Manage…** lists desktop and developer VMs, their resource allocations and
running state. Start or stop headless developer environments independently,
open a terminal or VS Code, verify a lock, or select a VM's main settings.
Several headless VMs can run concurrently. The launcher controls one desktop
at a time; opening a desktop from a headless boot requires a restart and a
confirmation so running work is not stopped silently.

**New Environment…** chooses the project, instance name, frozen base and
Python/Node/Rust/Docker profiles. An existing project manifest is reused;
otherwise the GUI creates the manifest and initial lock. **Build Base from
Ubuntu ISO…** creates a frozen bundle without requiring command line setup.
Build progress and errors are shown in the dialog. The project manifest and
lock are still ordinary files suitable for version control.

Local network overrides live in the VM's `developer-network.json`, outside its
package lock. These host-specific LAN permissions and public keys are not
inherited by an exported/imported environment. Imports clear the inherited
GUI-managed key file while retaining a fresh management identity.

## Create and reproduce a project

Use the `uvm` beside `omacvm` in a checkout, or the bundled
`UbuntuVM.app/Contents/Resources/omacvm/uvm`. The app's developer row copies
that path. Add it to your PATH with a symlink if desired; no shell, SSH or Docker
settings are changed merely by creating an environment.

First build a **fresh** base from the verified Ubuntu 26.10 Desktop ARM64 ISO:

```sh
uvm base build --iso /path/to/ubuntu-26.10-desktop-arm64.iso --output /path/to/ubuntu-base
uvm init --base /path/to/ubuntu-base --name myproject --profile python --profile docker
uvm lock
uvm create --locked
uvm shell
```

Base creation downloads and builds the guest GPU components. It freezes the
result into a directory containing `bundle.json`, `disk.img` and `efi-vars.fd`.
Keep that bundle as a versioned artifact alongside the exact UbuntuVM app
build. `uvm base inspect BUNDLE` verifies its checksums. An existing personal
VM cannot be selected as a base by this command.

Commit **uvm.json**, **uvm.lock.json**, provisioning scripts and language lockfiles.
The base path is local and may differ between Macs; its SHA-256 identity must
match. Share the base artifact separately, then run `uvm create --locked` on
another Apple Silicon Mac. `uvm lock` resolves inputs in a fresh disposable
instance and removes that instance after a successful shutdown. A failed build
is retained with its location and logs for diagnosis.

The manifest supports these fields (unknown fields fail):

| Field | Meaning |
|---|---|
| `schema`, `name` | Version 1 and a lowercase environment slug |
| `base` | Bundle `path` and descriptor `sha256`; every disk file is verified |
| `snapshot` | Fixed Ubuntu snapshot, such as `20261108T000000Z` |
| `profiles` | Any of `base`, `python`, `node`, `rust`, `docker` |
| `packages` | Additional apt names or explicit `name=version` selections |
| `provision` | Project-relative Bash scripts, hashed in the lock, run as the Linux user |
| `git` | Optional `url` and full immutable `commit`; checkout into the Linux project |
| `images` | Optional OCI references pinned with `@sha256:…`; requires `docker` |
| `resources` | Portable `cpus` and `memory_gb` defaults |
| `ports` | Explicit mappings such as `[{"host":3000,"guest":3000}]` |
| `auto_ports` | Discover guest TCP listeners on ports 1024–65535; default true |
| `idle_minutes` | Optional headless idle timeout; default null (keep running) |
| `ssh_agent` | Forward your Mac SSH agent; default false |
| `interop` | Opt-in list: `browser`, `clipboard`, `export`; default empty |
| `desktop_autologin` | Log the developer account into GNOME when requested; default true |

The lock records expanded profiles, scripts, base identity, provisioner hashes,
exact requested apt versions, the entire installed package inventory, runtime
binary identity and pulled container image IDs. Locked replay fails when these
inputs or outputs differ. `uvm verify` checks drift; `uvm provision` reruns the
locked provisioning on an existing environment. Provisioning scripts should
be idempotent. Use `npm ci`, `pip --require-hashes`, `cargo --locked` and pinned
download checksums inside those scripts. Scripts run from `~/Projects/NAME`.
Script bytes are checked again when copied and executed; edits during a build
fail validation before a new lock is published.

**The frozen base is the reproducible input.** Rebuilding a base from the same
ISO may retrieve newer installation dependencies or Chrome. The resulting base
gets a different hash. These are reproducible environment definitions and
package inventories, not byte-identical running disks: machine IDs, SSH keys,
timestamps and application state intentionally differ. Network side effects
inside arbitrary scripts cannot be made reproducible automatically. Package
snapshots and container registries must remain available, or be mirrored.

## Daily use

```sh
uvm up                         # cold-start on demand; remains running
uvm run -- python3 -m pytest    # argv, stdin, cwd and exit status are preserved
uvm run --cwd /tmp -- uname -a
uvm shell --root                # explicit administrative shell
uvm code                       # VS Code Remote - SSH into the Linux project
uvm docker compose up -d        # guest Docker CLI
uvm ports                      # localhost forwards and conflicts
uvm desktop                    # restart headless VM with a desktop window
uvm stop                       # orderly shutdown
uvm status --json
uvm list
```

Run inside a project to select its environment, or use `uvm --env NAME …`.
A local instance can have a different name with `uvm create --name other`;
use `--env other` for that instance. Projects live on the Linux NVMe disk for
Linux permissions and filesystem performance. `uvm sync [MAC_DIRECTORY]`
copies files into that project without deleting guest files; it excludes
`node_modules`, `.venv` and `.DS_Store`. This is a copy, not live bidirectional
sync. Pin a Git commit in the manifest for a reproducible initial checkout.
Dev containers can use the guest Docker Engine through Remote - SSH.

`uvm code` and `uvm ssh-config --install` explicitly add a managed Include to
`~/.ssh/config`, preserving its contents. `uvm ssh-config` only prints a
standalone configuration. The alias `uvm-NAME` starts the VM on demand and
pins its SSH host key. VS Code and its Remote - SSH extension must be installed.
`uvm docker-context` explicitly creates an SSH Docker context when the Mac
Docker CLI exists; only `--use` switches your current context.

The guest account has **no password**, and accepts its unique management SSH
key. Set a password yourself with `uvm run --root -- passwd USER` if needed.
Desktop autologin is intended for these local developer environments; set
`desktop_autologin` false to require a password you choose. SSH agent forwarding
is opt-in, including `uvm run --agent`; a trusted Linux process can use the
forwarded agent while that connection is active. Keys are not copied into Linux.
Private SSH checkouts also need trusted server host keys. A hashed provision
script can install pinned `known_hosts` entries before checking out a private repository.

The background supervisor owns QEMU independently of Terminal or the launcher
app. Closing a terminal does not stop Linux. `uvm desktop` gracefully stops a
headless boot and restarts it visibly, so save work first. CLI commands, editor
connections and localhost forwarding work alongside the desktop. The developer
row offers Terminal, VS Code, Ports and Stop. Starting a developer VM from the
app uses this same lifecycle. Desktop mode currently omits the regular VM's
camera/audio/clipboard/Finder-drop bridges; use explicit developer interop below.

Local CPU/RAM changes in the app's resource settings are honored on subsequent
starts without rewriting the portable manifest. No setting is silently lowered.
The default is 4 CPUs/8 GiB; free-page reporting returns unused Linux pages to
macOS. Containers and package profiles are ARM64; x86 emulation is not provided.

## Localhost and Mac integration

Forwards bind **127.0.0.1 by default**. Explicit GUI LAN rules bind to all Mac IPv4 interfaces. IPv4 and IPv6-loopback guest
listeners and published Docker TCP ports are discovered periodically (up to 64 automatic ports). Explicit
mappings stay configured even before a server starts. Conflicts are reported,
never resolved by terminating another Mac process. Stop the VM to remove its
forwards. An idle timeout treats dev servers, SSH sessions and running CLI jobs
as activity, and never shuts down desktop mode automatically.

Manifest opt-ins enable these guest commands:

```sh
uvm-host open http://localhost:3000
printf 'hello' | uvm-host copy
uvm-host paste
uvm-host export ./build/report.txt
```

Browser URLs must be HTTP(S). Clipboard text and exports are limited to 16 MiB;
exports go into `~/Downloads/UbuntuVM/NAME`, use collision-safe filenames, and
are revealed in Finder. The guest cannot supply a host executable or host path.
No Mac helper installation or permissions are needed for this private virtio
channel. Leave capabilities empty for untrusted projects.

## Clone and move

```sh
uvm stop
uvm export /path/to/environment-bundle
uvm clone --name experiment
uvm import /path/to/environment-bundle --name imported
```

Exports require a stopped disk. APFS clones are used when available; other
filesystems receive sparse copies. Imports/clones verify all bytes and rotate
management keys, Linux host keys and machine identity before accepting SSH.
They preserve project files and application state. **An environment export can
contain guest secrets and data**; inspect it before sharing. Host private SSH
keys are excluded, but this is not a guest-data sanitization tool.

For offline checks: `python3 -m unittest discover -s src/dev/tests -v`.
Disposable integration tests use `UVM_TEST_MODE=1`, `UVM_HOME`, `UVM_VMS_ROOT`
and `UVM_SSH_CONFIG` pointing at test-only directories.
