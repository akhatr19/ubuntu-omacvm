# Snapshots, forks and files

Open a VM's **More** menu on the VMs screen (or its project's menu).

## Checkpoints and branches

**Snapshots & Forks** creates disk checkpoints while Ubuntu is stopped. They
include the Linux filesystem, installed software, EFI state and compute/display
settings. They exclude RAM, logs and external Mac-folder contents. Shut Ubuntu
down cleanly first: this is a disk checkpoint, not a live application session.

Select a checkpoint and **Restore** to return to it. The current disk is saved
as another checkpoint before it is replaced. Host sharing and network publication
choices remain local to the destination VM.

**Fork New VM** creates an independent VM from the selected checkpoint. It gets
fresh management keys, a new SSH port and machine identity; Mac folder sharing and
published services start disabled. You can make further checkpoints on either
branch. The list shows each checkpoint's parent and originating VM.

On APFS the disk copies share unchanged blocks. Each branch still needs its own
RAM and CPU while running. Checkpoints live in `.ubuntu-checkpoints` beside the
VM folders: keep that hidden directory with the VMs when moving or backing them
up. These local checkpoints do not replace a backup on another disk. Restoring
requires the same bundled QEMU runtime; unsupported filesystems fail safely
rather than attempting a non-atomic replacement.

CLI equivalents:

```sh
./uvm snapshot --vm /path/to/Ubuntu list
./uvm snapshot --vm /path/to/Ubuntu create --name 'Before experiment'
./uvm snapshot --vm /path/to/Ubuntu fork --id CHECKPOINT_ID --name experiment
./uvm snapshot --vm /path/to/Ubuntu restore --id CHECKPOINT_ID
```

## Finder and Ubuntu Files

**Files, Finder & Sync** offers three separate operations:

- **Full Filesystem** exposes `/` in Finder read-only, including root-owned
  stored files. **Linux Home** is writable. Finder's Command–Shift–Period shows
  hidden files. Linux permissions, special files and live virtual filesystems
  are not faithfully represented by Finder; use Linux tools for system changes.
- **Mac folder** exposes one chosen folder at `~/Mac` in Ubuntu Files after the
  next boot. This is live access: Linux edits change Mac files immediately.
- **Sync** copies between a selected Mac folder and an absolute Linux folder.
  Preview first, then choose the direction. Newer destination files are kept;
  nothing is deleted. Replaced files receive timestamped backups. This is manual
  directional sync, not a continuous conflict-merging service. `node_modules`,
  `.venv` and `.DS_Store` are excluded.

Enable Finder sharing by choosing a separate sharing password in the app.
Samba and rsync are installed inside Ubuntu. The password travels through the
private guest-agent channel and is not put in URLs, arguments or host settings.
The file server listens only inside the guest on loopback; Finder reaches it
through an authenticated SSH tunnel bound to Mac loopback. This private service
uses SMB 2.1 for compatibility with the tested macOS client; SSH supplies transport
encryption and integrity. It is not a LAN share.
macOS handles any Finder credential prompts. Eject Linux drives before stopping
Ubuntu; the home-screen Stop action attempts to eject them first.

For reproducible environments, include the **Files** provisioning profile in the
manifest and lock. Installing these packages into an existing locked environment
can make verification report package drift. Sync backups are under
`~/.local/share/ubuntu-vm/sync-backups` in Linux or UbuntuVM's Application Support
`sync-backups` directory on the Mac. Finder requires a running guest; it cannot
browse an offline raw Linux disk.

## Saving RAM to disk

Not supported by this accelerated runtime. The shipped QEMU rejects its current
GPU configuration with `-only-migratable`: **virgl is not yet migratable**.
Reliable hibernate/resume would require graphics migration support, compatible
device/runtime state, crash recovery and explicit handling of external files
and network sessions. It is not a trivial pause feature. Stop Ubuntu to reclaim
its resources; disk checkpoints remain available for restarting from saved data.
