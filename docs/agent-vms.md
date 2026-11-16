# Future agent VMs

The hybrid Projects / VMs model keeps project folders independent of VM ownership.
An agent could lease a VM and work on several projects, while humans keep their own
VMs. Agent ownership and computer-use APIs are future work; they are not enabled by
Build 5.

Each agent should receive a unique VM identity, SSH credentials and a local access
capability scoped to that VM. A host controller would offer start, stop, command
execution, file transfers, screenshots and input. It must not expose unrestricted
QMP or Mac input helpers to the guest or agent. Agent VMs should not receive the
Mac clipboard, gestures, bridge token, home directory or SSH agent by default.

Keep three execution modes separate: compute-only headless, a human desktop,
and an agent desktop. The agent mode needs a real guest graphical session while
keeping the Mac window hidden. Today the compute-headless path stops GNOME, so
it is not sufficient by itself for agent computer use.

Use a private guest display connection for computer use. QEMU provides screenshot
and input commands through [QMP](https://www.qemu.org/docs/master/interop/qemu-qmp-ref.html);
a private VNC transport is another candidate. The first prototype must verify
capture and input with this patched GPU runtime, independent desktops for two
VMs, and no changes to the Mac's pointer or focus. An optional viewer can show the
same agent desktop to a person. Mac windows and Spaces should not be the agent's
control surface.

A shared resource pool can make many stored environments affordable:

- Clone the immutable Ubuntu base with copy-on-write disks, retaining separate
  writable state and credentials per agent. Existing base bundles are a starting
  point; clones still consume space as their contents diverge.
- Share read-only package/container download caches through a cache service.
  Writable project folders stay private; file exchange is explicit.
- Queue work when the host's CPU, memory and active-VM budgets are exhausted.
  Give the user's interactive VM priority. Start only the VMs doing work, then
  shut idle ones down to release their memory.
- Keep free-page reclamation. It releases unused pages; it does not make active
  application memory common to multiple VMs. Pausing a VM also does not release
  its RAM. Saved-state resume and GPU compatibility require separate testing.

Do not promise cross-VM RAM deduplication or a particular number of simultaneous
browser desktops. Measure real memory use and capture compatibility on this Mac
before setting concurrency defaults. A pool of stopped, ready-to-start clones is
the first implementation; transparent live migration and shared writable RAM are
not prerequisites.
