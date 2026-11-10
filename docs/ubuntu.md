# Ubuntu Desktop port

This branch adds an Ubuntu 26.10 ARM64 installation route while retaining
OmacVM's patched QEMU runtime, accelerated virtio GPU and free-page reclamation.
It uses GNOME and does not install Omanotch or the Mac Bridge/Gestures helpers.

## Build a VM

The source-tree command needs the existing runtime and firmware under
`app/runtime/.build`, produced by `app/scripts/build-app.sh`. For development,
the corresponding runtime and firmware from the verified upstream release can
also be used; an ordinary Homebrew QEMU does not have the required patches.
Build the Ubuntu launcher around the official OmacVM 3.4.1 release app:

```bash
app/scripts/build-ubuntu-app.sh /path/to/OmacVM.app /path/to/UbuntuVM.app
```

The output path must be new. The script checks that the runtime's source
commit matches and that this fork has not changed its runtime patches,
compiles the launcher, packages the Ubuntu sources and orange terminal icon,
and ad-hoc signs the result. Xcode is required. Its bundle ID is
`org.omacvm.ubuntu`; its default VM folder is `~/UbuntuVMs`. Builds are labeled **0.1 Dev Build #N** in the installer and app window.
Packaging automatically increments `N`, recording it in `CFBundleVersion` and
`app/.build/ubuntu-build-number`; it also checks installed build numbers so an
existing newer installation is never assigned an older number. Keep that counter
when cleaning build artifacts. The upstream integration version in `src/VERSION`
is separate from the Ubuntu app version.

Open `app/dist/UbuntuVM.app` to install or update. A build/download copy only
shows the installer; it cannot start VMs or hand off silently to an older app.
The installer searches `/Applications`, `~/Applications`, and the last chosen
installation path (including renamed copies), preselects the newest installed
build, shows both versions, and offers **Update and Open** when appropriate.
An equal or older build offers **Open Installed App** and cannot downgrade it.
Quit the installed app and its VMs before updating. The replacement is staged
before the existing app is moved, with rollback if the final move fails.

The first launch offers **Install and Open** to copy the app into Applications;
there is no try/skip-install path. The installer shows the full destination:
`/Applications` for all users or `~/Applications` for only your account. Existing
installations retain their location unless you choose another. When moving an
installation, an explicit checkbox moves the previous app to Trash after the
new copy is ready; VM data stays outside the app. The build/download copy is
unregistered from the launcher after installation. **Developer & SSH → App
location → Show in Finder** reveals the copy actually running. Previous skip
choices are ignored.
Permission prompts remain macOS's normal human choices. Upstream OmacVM app
updates are disabled for this fork so they cannot replace the Ubuntu port.

The app's **New VM** screen accepts the official Ubuntu ISO, user name,
password and resource choices. It checks the ISO checksum and runs the same
Ubuntu installer as the CLI below. No Omarchy image or prebuilt lookup runs.
The installer needs at least 6 GB of configured VM RAM; 8 GB is recommended.

Download `ubuntu-26.10-desktop-arm64.iso` from
[Ubuntu's official release directory](https://cdimage.ubuntu.com/ubuntu/releases/26.10/release/).
The command verifies its pinned SHA-256 before creating anything.

```bash
./omacvm ubuntu build --iso /path/to/ubuntu-26.10-desktop-arm64.iso \
  --vm-name Ubuntu --user yourname --cpus 4 --memory-gb 8 --disk-gb 64
```

It asks for the Ubuntu account password (or reads `OMACVM_PASSWORD`), installs
from the official Desktop ISO using NoCloud autoinstall, then installs the
Ubuntu guest components over the VM's own SSH key. The password is hashed
before entering the seed image; the temporary seed is removed on exit. The
installer selects only the new disk with serial `omacvm`. An existing VM
folder is refused. The SSH forward defaults to localhost:52224; choose another
with `--ssh-port`. `OMACVM_VMS_ROOT` overrides `~/UbuntuVMs`. A guest setup
that failed after Ubuntu installed can be retried with
`./omacvm ubuntu resume --vm-name Ubuntu`, without reinstalling its disk.

`OMACVM_UBUNTU_TEST=1` uses a locked account only for names beginning with
`OmacVM Test-`; this is for disposable tests, not an account to log into.

## Graphics, compute and video

Ubuntu retains its packaged Mesa for desktop OpenGL, VA-API and Rusticl.
Only Venus is built separately in `/opt/omacvm-venus`, using upstream OmacVM's
Mesa 26.2.4 source pin and semaphore/TLS patches. It does not replace Ubuntu's
Mesa packages. Session configuration selects that ICD and enables Rusticl on
Zink for OpenCL. The Mac app's existing Vulkan readiness marker is written
only after the guest installation succeeds.

The existing VA-API and EGL shims are built against Ubuntu's headers and
multiarch driver path. GNOME Shell bypasses the EGL shim, as Hyprland does.
mpv uses OpenGL presentation and VA-API decoding.

Google's ARM64 Chrome .deb is installed inside the guest. Two launchers are
provided:

- **UbuntuVM Video Browser:** Wayland browser for hardware video decoding.
- **UbuntuVM WebGPU Browser:** separate profile, Xwayland/Vulkan compositor,
  hardware WebGPU, software video decoding. This follows upstream's buffer
  sharing limitation; combining both in one browser remains out of scope.

Ubuntu's default Snap Firefox uses a separate graphics runtime and is not
configured to load these guest libraries. The port does not disable browser
sandboxing or use `--no-sandbox`.

## Verify

After starting the VM with OmacVM's accelerated graphics, run:

```bash
./omacvm ubuntu check --vm-name Ubuntu
```

This checks the guest agent, free-page reporting, Venus, Rusticl's Zink device,
VA-API decode profiles and browser installation. It does not prove decoded
playback or WebGPU execution by itself. Validate playback with mpv and the
browser's media diagnostics; run `src/bench/pages/webgpu-matmul.html` and check
both its numerical result and hardware adapter. Compare host memory before
and after allocating/freeing guest memory, including macOS's reclaim log.

## Desktop integration

- **Native cursor:** enabled by default in UbuntuVM. GNOME places its cursor
  on the stock virtio hardware cursor plane; QEMU uses that image and hotspot
  as the real macOS cursor and hides its extra cursor layer. The Display
  section has a **Native Mac pointer** switch, effective next start. Relative
  mouse input (games) retains the existing fallback.
- **Clipboard:** text and PNG images in both directions, with the existing
  16 MiB limit and echo protection. A small GNOME 51 extension observes the
  selection because GNOME lacks the data-control protocol used by the
  Hyprland agent. No shell-eval or portal-security settings are changed.
- **Displays:** a session agent uses Mutter's DisplayConfig API to apply
  the host's modes, scale and layout and report logical geometry back to
  QEMU. Changes are temporary, preserving Ubuntu's saved monitor settings.
  It responds to hotplug/layout events instead of polling while idle.
- **Files:** choose **Mac folder** in the app; it mounts at `~/Mac` next boot.
  Only the selected folder is exposed. **Finder drops** copy files dropped on
  the VM window into Ubuntu's Downloads folder, using numbered names when a
  file already exists. New VMs enable this by default. The staging share is
  read-only; files only, up to 256 per drop. GNOME does not expose the
  Hyprland protocols for app-target drops, so this port uses Downloads.
- **Media/audio:** the upstream MPRIS agent provides Now Playing and media
  controls; host output latency is applied to PipeWire for video sync.
- **Battery/camera:** the existing battery module and v4l2loopback camera
  build through Ubuntu DKMS/headers. New Ubuntu VMs enable these host ports.
  Camera capture still requires the person's macOS permission when used;
  installing its guest device does not grant that permission.
- **Settings:** the VM's Features menu opens Ubuntu Settings. **Update VM**
  updates the Ubuntu integrations without invoking the Omarchy installer or
  replacing the Mac's helpers.

For an existing Ubuntu VM, change the optional device/drop settings through
the installer while the VM is shut down (do not edit its feature record):

```bash
app/scripts/update-vm.sh "$HOME/UbuntuVMs/Ubuntu" --no-mac \
  --feature battery=on --feature camera=on --feature drag-drop=on
```

Use `off` to remove either guest device and stop its host relay next start.
For a running VM, `app/scripts/apply-vm.sh VM_DIR --no-mac --feature …` uses
the same route. Both keep the host feature record and guest environment in
sync. The Ubuntu app also has Enable/Disable controls for Finder drops and
gestures; other Omarchy feature switches remain unavailable on Ubuntu.

**Trackpad gestures:** click **Install Helper and Enable…** under Input while
the VM is shut down. This explicitly installs the packaged OmacVM Gestures
Mac helper as a login item, provisions its authentication token safely as the
guest user, and enables the guest's virtual trackpad. Grant Accessibility and
Input Monitoring in macOS when prompted. The Bridge app and Omanotch are not
needed. Full-screen three-finger swipes are handled by GNOME itself; the
Hyprland workspace queries and swipe-out interception are disabled. The
virtual touchpad's tap-to-click is off to avoid duplicate Mac clicks.

For manual setup, run `app/scripts/install-ubuntu-gestures.sh`, then the
update command above with `--feature gestures=on`. Turning gestures off does
not uninstall the shared Mac helper or reset its permissions.

Omanotch and Omarchy's shell/theme migration are omitted. Full screen uses
the area below the notch. Touch ID, Mac IME and HDR are outside this port's
scope. Invisible-window DPMS remains unavailable; ordinary mouse input,
scrolling and keyboard input remain on the existing QEMU path. Only the
person installs the Mac helper and grants its permissions.

## Validation on this port

Tested on an M5 Pro with macOS 27, Ubuntu 26.10's stock 7.3.0-10 kernel
and packaged Mesa 26.2.4:

- Installed from the pinned Desktop ARM64 ISO and booted from its NVMe disk.
- Venus and Rusticl/Zink identify the Apple M5 Pro through KosmicKrisp.
- WebGPU's matrix multiplication completed on the Apple adapter with its
  numerical result checked against the CPU reference.
- An OpenCL GPU kernel returned all 4096 expected integer results.
- FFmpeg decoded 60 H.264 frames with VA-API; every frame hash matched the
  software decoder. Chrome playback reported `VaapiVideoDecoder` and
  `kIsPlatformVideoDecoder=true`.
- After a 1 GiB allocation was freed, QEMU's reclaim checks showed reported
  pages left neither resident nor compressed on the Mac.
- The EGL vendor regression tests passed on Ubuntu, including GNOME Shell's
  bypass. The Mac launcher build, shell syntax/ShellCheck and the upstream
  memory/graphics regression checks passed.

GPU execution and decoding were tested with a hidden QEMU window. This does
not validate visible presentation pacing, HDR, or every codec. Rusticl emits
upstream warnings about Zink's missing custom-border-color support and the
distribution's libclc; the compute smoke test passes, but full OpenCL
conformance and individual applications have not been established.

Additional Ubuntu integration validation:

- Unicode text and PNG clipboard round trips passed on a private Mac
  pasteboard, without changing the user's pasteboard during the test.
- GNOME's DRM cursor plane became active after absolute pointer input; the
  packaged launcher enabled native hardware-cursor handling by default.
- Mutter followed the host's 2× scale, and reapplied it after a GNOME change.
- The selected Mac test folder mounted through 9p; reads and writes passed.
- UPower received the Mac battery level, the camera module exposed
  `/dev/video42`, and the host's audio latency appeared on the guest output.
- Guest checks and media/audio regression tests passed. Camera capture,
  physical multi-display layouts and visible cursor behavior still require
  interactive testing with the person's permissions and displays.

The Ubuntu device off/on cycle was also verified against both the guest
devices and the persisted host/guest feature settings.

Finder/gesture validation used a hidden disposable Ubuntu VM:

- QEMU's real drop handler, DropServer, read-only 9p share and guest agent
  delivered text and binary files with spaces/symbols in their names; hashes
  matched. A repeated drop preserved the original and created a numbered copy.
- The gestures connection authenticated both peers using the existing HMAC
  protocol. Replayed three-finger frames reached libinput as a swipe and
  changed GNOME workspaces; a GTK window lost focus and regained it on the
  return swipe. No Mac desktop input was injected.
- The physical Mac trackpad and permission prompts still require the person;
  the transport test used a stand-in Mac sender with a disposable token.

## Gestures helper location

The Ubuntu installer labels the helper **UbuntuVM Gestures** and installs it at
`~/Applications/UbuntuVMGestures.app`. Under Input, **Show Helper** reveals the
actual installed bundle; **Permissions** opens Accessibility and Input Monitoring
and includes **Install / Repair Helper…**. Only the person grants those macOS
permissions. Existing legacy helper paths remain detectable during migration.
Internal `org.omacvm.*` service identifiers and compatibility commands are kept;
they do not indicate that a separate Omarchy installation is running.

### Gestures permissions

In **Input → Gestures helper → Set Up Permissions**, use **Show Exact Helper**
or **Copy Helper Path**. Grant access to `~/Applications/UbuntuVMGestures.app`,
not the UbuntuVM launcher or a helper nested inside a build. In both Accessibility
and Input Monitoring, click **+**, press **Command–Shift–G**, paste that path and
select the helper. Enable its switch. Remove obsolete helper entries if they
remain enabled but do not work, then add this exact copy again.

Use **Restart Helper** after granting access and **Check Permissions Again**.
The two grants are shown separately from the running helper's own log, with its
process identity checked; an old report or the launcher's privacy identity cannot
stand in for the current helper. **Repair Helper** reinstalls the packaged helper
if it is missing. Your VM disk and settings are preserved.

See [Snapshots, forks and files](snapshots-and-files.md) for disk restore, branches, Finder access and directional sync.
