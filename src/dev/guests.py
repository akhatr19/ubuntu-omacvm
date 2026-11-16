"""Guest identity is independent of the launcher branding; missing markers are legacy Omarchy."""
from pathlib import Path


def profile(vm):
    marker = Path(vm) / 'guest-os'
    if not marker.exists(): return 'omarchy'
    if marker.is_symlink() or marker.stat().st_size > 32: raise ValueError('invalid guest profile')
    name = marker.read_text().strip()
    return name if name in ('ubuntu', 'omarchy', 'custom') else 'custom'
