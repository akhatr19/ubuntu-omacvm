# Developer environments

## VMs and Projects in the app

The SwiftUI Workbench keeps **Projects** and your VM list in the sidebar. Select
a VM to see Overview, Projects, Network & SSH, Files, Snapshots, Resources and
Input in one place. The launcher remains available while Ubuntu runs. Opening
UbuntuVM from its Dock icon shows the Workbench; **Show Desktop** explicitly
focuses the separate UbuntuVM Desktop window. Start requests from the CLI remain
explicit. Closing the launcher window leaves the VM running; quitting the app
still follows its shutdown behavior.

**App Settings → Default editor** detects VS Code and VS Code Insiders, or lets
you choose another installed application. Install Remote - SSH in that chosen
editor. The same choice is used by project buttons and `uvm code`; `UVM_CODE`
remains an explicit command-line override. Missing editor installations fail
before a stopped VM is started. Editor preferences are stored in UbuntuVM's
Application Support `editor.json` (or `UVM_HOME` when set).

Several projects can share a VM, or use separate pinned tools through
**New VM → Reproducible Environment → Create & Open Project**. That flow copies
the selected Mac project's files once after provisioning.

**Add Project** can attach an existing Linux folder, clone an HTTPS/SSH Git
repository, import a Mac folder, or create an empty folder. Opening a project
starts its environment and waits for authenticated SSH. Managed environments
start headless; an existing desktop VM starts through its desktop launcher.
Terminal opens at the Linux folder, and VS Code uses Remote SSH. Git is installed
if missing in an ordinary desktop VM; locked developer environments keep their
provisioned tools. SSH cloning uses credentials available in Ubuntu; no Mac
private key is copied automatically.

Project actions include a Dev Container check, editor opening, lock verification,
import and export. Dev Container opening checks for `.devcontainer/devcontainer.json`
or `.devcontainer.json` and a running Docker engine in Ubuntu, then opens the
Linux folder through Remote SSH. Select **Dev Containers: Reopen in Container**
in VS Code's prompt/command palette; the Remote SSH and Dev Containers extensions
are required. This uses VS Code's documented remote-host workflow rather than
undocumented container URI formats. A Docker-enabled environment profile supplies
the guest engine. Ordinary desktop VMs need Docker installed separately.

Imports preserve existing Linux files and exclude node_modules/.venv and Mac
metadata. Exports create a private, new `.tar.gz` archive; the app never extracts
guest-controlled paths onto the Mac. Exports are capped at 4 GiB and leave at
least 2 GiB free. **Forget Project** removes the shortcut, keeping Linux files and
the VM. Projects are saved in the app's preferences, outside the Git repository.

**Ports & SSH** separates localhost addresses from LAN addresses, includes browser,
copy and connection-test actions, and reports developer forward conflicts.
**SSH Keys & Settings** edits forwards while stopped, with **Find Free Port** for
choosing a host port. Changes publish at the next boot. HTTP browser buttons are
for websites; database and other protocols use the same addresses in their clients.
Testing localhost confirms only the Mac listener, not remote-LAN reachability or
application health.

The equivalent CLI is `uvm workspace --vm VM_FOLDER --project /home/USER/Projects/NAME
ACTION [SOURCE]`. Desktop VMs also need `--qga SOCKET`, supplied by the GUI. Actions
include `info`, `init`, `clone`, `import`, `export`, `terminal`, `code`, and
`container`. SSH host identity is pinned through the VM's private guest agent.

Agent-owned desktop VMs and resource pooling are a future design, described in
[agent-vms.md](agent-vms.md). This build does not add agent computer-use control,
performance presets or diagnostics/recovery flows.

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

### Personal data independent of a VM

Workbench → Files → **Personal data across VMs** manages expandable ext4 disks
outside VM folders, in `.ubuntu-data` beside the VMs. Create a disk, choose
folders, and select **Attach & Set Up** while the VM is stopped. Setup boots
privately without networking, a display or shared Mac folders, then shuts down.
It requires a working QEMU guest agent and a desktop account with UID/GID 1000.
The current VM installer supports Ubuntu; this does not add other distro installers.

First setup copies selected Projects, Documents, Downloads, Pictures, Music and
Videos folders into a new disk. Original folders stay on the system disk. Bind
mounts make the shared versions appear at their usual home paths; detaching
reveals the originals again. Existing disks keep their own data rather than
merging another VM's local folders. Dotfiles, desktop settings, credentials,
installed tools and caches remain per VM. Project-local `.venv`, `node_modules`
and build outputs still travel with Projects and may need rebuilding when switching
distros; use per-VM toolchains or devcontainers where possible. Copying originals uses additional
space; review them yourself before removing anything. Finder's existing Home
share can browse the mounted personal folders while that VM is running.

Only one VM can own a writable data disk. Attaching elsewhere automatically releases its previous VM when both are
stopped. Running owners are refused. Even a paused QEMU process retains ownership. A missing disk or
incomplete setup blocks normal startup rather than creating an empty replacement.
Deleted VMs leave their data disks intact and available to attach elsewhere.
An interrupted first format is never repeated automatically: repair can mount
an already-created matching filesystem; an unformatted interrupted disk may
need replacing with a newly created disk. No source folders are deleted.

Data snapshots are independent of system checkpoints and require the owning VM
to stop. A data fork clones a selected snapshot into a new, detached disk for
experiments or agents; changes are independent and are not merged. Data restore
requires detachment and saves a snapshot of the current data first. These local
snapshots are not backups against loss of the Mac or its drive. System checkpoints
and environment exports exclude personal data. A system restore keeps the
attachment but requires **Repair / Reconfigure** before boot, since the restored
guest may contain older mounting software. System forks start without a data disk.
Coordinated system-and-data restore is not provided. Raw disk attachments stay
exclusive; use Live shared folders below for concurrent access.

The same operations are available through the packaged CLI:

```sh
uvm data --vm /path/to/VM create --name Personal --size-gb 64
uvm data --vm /path/to/VM list
uvm data --vm /path/to/VM attach --id DATA_ID --folder Projects --folder Documents
uvm data --vm /path/to/VM snapshot --id DATA_ID --name 'Before experiment'
uvm data --vm /path/to/VM snapshots --id DATA_ID
uvm data --vm /path/to/VM fork --id DATA_ID --snapshot-id SNAPSHOT_ID --name Agent
uvm data --vm /path/to/VM detach
uvm data --vm /path/to/VM restore --id DATA_ID --snapshot-id SNAPSHOT_ID
```

### Shared home folders (the default Files workflow)

Workbench → Files → **Shared home folders** uses ordinary Mac folders as the
source of truth. By default, `~/Linux/Desktop`, `~/Linux/Documents` and
`~/Linux/Downloads` appear at `~/Desktop`, `~/Documents` and `~/Downloads` in
every enabled distro. Your Mac's own Desktop, Documents and Downloads are
unrelated. The rest of each Linux home, including dotfiles, settings and app
data, stays on that VM's disk. Add a simple folder name such as `Developer`
to share `~/Linux/Developer` at `~/Developer` in each distro.

The folder list is Mac-wide; the enable switch is per VM. Changes apply after
restart. Existing desktop VMs receive the boot helper through the app's held
guest-agent connection; recreating a VM is unnecessary. Files shows the current
startup's setup progress or failure separately from the enable switch.
New VMs default to sharing; existing raw personal-disk attachments
keep their previous behavior until detached. At startup the app creates only
the configured Mac folders and exports each separately through virtio-9p.
No storage VM, network service, Finder password or synchronization copy is
needed. Mac access works with every VM and the app closed. Missing permissions
or symlinked source folders cause an explicit startup error.

Before mounting, nonempty local Linux folders move into
`~/UbuntuVM Local Folders/<name>-<id>`. They are not merged into or allowed to
overwrite the shared files. Move any wanted originals into the shared folders
yourself. Turning sharing off, or removing a folder mapping, restores its
original local directory on the next boot. Shared Mac files are retained.
Legacy Linux-backed shares remain available under Advanced; existing data is
never automatically converted or deleted.

Multiple VMs and Mac apps can edit the same files while running. The mounts
disable data/writeback caching to avoid retaining other clients' old contents.
External changes do not guarantee Linux inotify events: use polling for editors
or development servers that need it. This is shared storage, so simultaneous
edits to one document still need coordination. The current 9p backend does not
coordinate file locks with Mac apps; do not depend on cross-system locking.
APFS case sensitivity and Mac
filesystem semantics apply. Keep databases, containers and build caches on
private Linux storage, and use separate Git worktrees for independent agents.
VM snapshots exclude these Mac files; back up `~/Linux` on the Mac separately.

```
uvm home-folders --vm /path/to/VM list
uvm home-folders --vm /path/to/VM add --name Developer
uvm home-folders --vm /path/to/VM disable
uvm home-folders --vm /path/to/VM enable
```

### Linux-backed live shared folders (Advanced)

Workbench → Files → Advanced also provides **Shared folders**. Create one from a stopped
VM, or convert an existing personal disk. First setup makes a private copy of
that VM's system in `.ubuntu-services`, gives it fresh management credentials,
and prepares a background file service. The original system and local home
folders are preserved. This requires the source VM to be stopped once; it does
not copy a running filesystem or stop another VM without asking.

Choose **Use in This VM** for each VM. Files appear under
`~/Shared/<name>-<id>`; connecting does not hide local home folders and works
while the VM is running. Several connected VMs and **Open in Finder** can read
and edit the same files concurrently. Finder uses an authenticated, writable
SMB share through private SSH. Linux uses NFSv4 through private SSH forwards.
Neither service is published to the LAN. Clients receive stable, distinct NFS
identities so cloned VMs with identical hostnames keep independent lock state
([kernel client-identity documentation](https://cdn.kernel.org/doc/html/latest/filesystems/nfs/client-identifier.html)). The file service remains available
when desktop VMs stop, so Finder does not depend on a desktop staying open.

Normal VM startup reconnects registered folders before allowing desktop login;
managed environments also wait for their folders before reporting ready.
Connection failure leaves the data intact and reports an error; it does not
substitute an empty data directory. Removing a connection unmounts normally
and refuses busy files. It does not delete shared data. Stop File Service first
ejects its Finder mounts and refuses while a connected VM is running.

The service uses one CPU and up to 2 GB guest RAM, with free-page reclamation,
and has no GPU, desktop window, Mac shares, or published LAN ports. Its cloned
system shares physical blocks on APFS until changed. Each shared data disk has
one service; adding clients does not create more storage VMs. Do not delete the
hidden service folder manually: it contains the service's credentials and OS.
The data disk remains in `.ubuntu-data`, outside all desktop VM folders.

Clients need UID/GID 1000 and `nfs-common`. The optional **sharing** provisioning
profile pins this prerequisite for locked environments. Unlocked clients install missing support. Locked clients refuse missing
prerequisites until the sharing profile is provisioned, preserving their package lock. These are
live network filesystems, not a bidirectional copy/sync system: simultaneous
edits follow normal shared-file rules. Use separate working copies for concurrent
Git operations, keep build caches and databases local when they require local
filesystem semantics, and use polling for tools whose file watchers do not see
changes originating on another machine.

Raw disks and directional sync remain under **Advanced: disks, file services
and sync**. Raw disk attachment automatically releases a stopped previous VM;
it refuses running owners. Shared-folder backing disks cannot be stolen through
the raw attachment controls. Data snapshots still require the file service to
be stopped; coordinated system/data checkpoints are not provided.

Workbench → **Connections** exposes **Connect to this VM** and **Publish a
service** directly. A published service chooses a Linux port, a Mac port and
Only this Mac or Local network access. These settings apply at the next start.
SSH keys, automatic discovery, idle behavior and the network engine remain in
Advanced controls.

```sh
# First creation reads the Finder sharing password from stdin.
uvm sharing --vm /path/to/VM create --name Personal --size-gb 64
# Or convert an existing independent data disk:
uvm sharing --vm /path/to/VM create --id DATA_ID
uvm sharing --vm /path/to/VM list
uvm sharing --vm /path/to/VM use --id SHARED_ID
uvm sharing --vm /path/to/VM connect --id SHARED_ID
uvm sharing --vm /path/to/VM remove --id SHARED_ID
uvm sharing --vm /path/to/VM stop --id SHARED_ID
```
