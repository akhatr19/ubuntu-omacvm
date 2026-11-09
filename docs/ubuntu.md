# Ubuntu Desktop port

This branch adds an Ubuntu 26.10 ARM64 installation route while retaining
OmacVM's patched QEMU runtime, accelerated virtio GPU and free-page reclamation.
It uses GNOME and does not install Omanotch or the Mac Bridge/Gestures helpers.

## Build a VM

The source-tree command needs the existing runtime and firmware under
`app/runtime/.build`, produced by `app/scripts/build-app.sh`. For development,
the corresponding runtime and firmware from the verified upstream release can
also be used; an ordinary Homebrew QEMU does not have the required patches.
Build a separately named app with `app/scripts/build-app.sh --name UbuntuVM
--id org.omacvm.ubuntu`, and point its VMs folder at `~/UbuntuVMs`. The
development copy is kept separate from upstream OmacVM; upstream releases do
not contain this Ubuntu port.

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

- **OmacVM Browser:** Wayland browser for hardware video decoding.
- **OmacVM Browser (WebGPU):** separate profile, Xwayland/Vulkan compositor,
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

GNOME-specific display synchronization, gestures, clipboard, host hardware
panels, camera, Touch ID and the full feature control centre are separate
follow-up work. The Ubuntu route refuses the Omarchy guest installer.

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
