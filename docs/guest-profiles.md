# Guest profiles and upstream maintenance

One Workbench lists Ubuntu, Omarchy and custom ARM64 guests. The installed app
and helper bundle identities stay unchanged so updating does not create another
application or permission identity. Choose a profile in New VM; it is recorded
per VM in `guest-os`, independently of the app's branding.

| Profile | Installation | Default integration |
| --- | --- | --- |
| Ubuntu | Checksum-pinned Ubuntu 26.10 ARM64 ISO, automatic setup | GNOME clipboard/displays, graphics/compute/video, camera/battery, Finder drops and shared home folders |
| Omarchy | Upstream signed prebuilt image or Arch Linux ARM build | Upstream feature defaults, including Bridge, gestures and Omanotch on a notched Mac; shared home folders |
| Custom ISO | Private copy of an ARM64 UEFI installer, manual setup | Basic virtio display/network/audio output, memory balloon device; no Mac shares, clipboard, gestures or automatic guest changes |

Touch ID, Mac IME, Mission Control and experimental Omarchy features remain
available through All VM Settings and the guest control centre, with the
upstream defaults rather than unconditional enablement. Mac permissions remain
human decisions. Ubuntu and Omarchy use the same developer SSH/editor model;
frozen-base developer environment creation still targets Ubuntu.

Defaults are read from `src/features.tsv` through `GuestProfile`. They apply only
to new VMs. Existing feature records, resource choices, data disks and sharing
switches remain authoritative. A missing profile marker identifies a legacy
Omarchy VM; an unknown profile is treated as a custom guest. Ubuntu VMs keep
their existing marker and do not require recreation.

Custom ISO creation records the copied media's SHA-256 and original filename
in `iso-source.json`. The target is ARM64, not x86 emulation. Compatible firmware,
virtio drivers and guest installation remain the ISO's responsibility; choosing
an ISO does not imply GPU acceleration, WebGPU/OpenCL, hardware video decode or
free-page reporting support. Shut down, select Installation Finished — Eject ISO,
then boot the installed disk. The ISO copy is retained for reproducibility.

After installing Ubuntu 26.10 or Omarchy manually, enable the guest agent and
OpenSSH server inside Linux. Detect Installed Linux reads the guest identity and
UID-1000 account. Shut down before enabling its detected profile and updating
guest tools. Other distributions keep basic operation until a verified profile
is implemented. Configs and app data stay private; supported Linux profiles can
share Desktop/Documents/Downloads through `~/Linux` as described in the
[developer guide](developer-environments.md#shared-home-folders-the-default-files-workflow).
Linux-backed data disks and NFS/SMB file-service provisioning currently remain
Ubuntu-specific; the ordinary Mac-backed home folders support both profiles.

## Upstream updates

The fork includes a normal merge of OmacVM `v3.4.6`, preserving Git ancestry.
For the next update, fetch upstream, merge a stable release on an integration
branch, resolve the overlapping launcher/guest files, and run Ubuntu, Omarchy
and custom-ISO checks before delivery. Keep runtime source and the official app
artifact at the same recorded commit; verify the release checksum before use.
Never point the fork's app updater at upstream's installer.

`build-ubuntu-app.sh UPSTREAM_APP OUTPUT_APP [COMPAT_APP]` packages the matching
runtime. A compatibility app retains approved older runtime bytes under their
content hash. Managed environments and frozen bases continue selecting their
pinned runtime; missing or modified archived runtimes are refused. The
`SOURCE_COMMIT` record identifies the matching source in Git history. Source
imports, guest setup and runtime/package locks are separate operations.

Validation includes profile/default tests, legacy-marker loading, modified
runtime refusal, native guest-agent/SSH setup, real disposable guests and native
offscreen layouts. Native VM tests use a test bundle identity, hidden QEMU
windows, private clipboard and `OmacVM Test-*` VMs, leaving installed helpers
and personal VMs untouched.
