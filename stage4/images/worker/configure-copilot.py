#!/usr/bin/env python3
"""Seed missing Copilot defaults and migrate the previously provisioned launcher."""

import os
from pathlib import Path
import re
import shutil
import sys
import tempfile


def import_legacy_sessions(home: Path, config: Path) -> None:
    legacy = home / '.copilot/session-state'
    if not legacy.is_dir():
        return
    sessions = config / 'session-state'
    for source in legacy.iterdir():
        if (source.is_symlink() or not source.is_dir()
                or not re.fullmatch(r'[A-Za-z0-9_-]+', source.name)
                or not (source / 'events.jsonl').is_file()
                or (source / 'events.jsonl').is_symlink()):
            continue
        destination = sessions / source.name
        if os.path.lexists(destination):
            continue
        sessions.mkdir(mode=0o700, exist_ok=True)
        temporary = Path(tempfile.mkdtemp(prefix='.native-import-', dir=sessions))
        try:
            shutil.copytree(source, temporary / 'session', symlinks=True)
            if not os.path.lexists(destination):
                os.rename(temporary / 'session', destination)
        finally:
            shutil.rmtree(temporary)


def configure(home: Path, seed: Path, launcher: Path) -> None:
    config = home / '.copilot-cici-super'
    config.mkdir(mode=0o700, parents=True, exist_ok=True)
    for source in seed.iterdir():
        if not source.is_file():
            continue
        destination = config / source.name
        if destination.exists() or destination.is_symlink():
            continue
        fd, temporary = tempfile.mkstemp(prefix='.copilot-default-', dir=config)
        try:
            with os.fdopen(fd, 'wb') as output:
                output.write(source.read_bytes())
                output.flush()
                os.fsync(output.fileno())
            try:
                os.link(temporary, destination)
            except FileExistsError:
                pass
        finally:
            os.unlink(temporary)

    # Early provider probes in older workers used the default Copilot home.
    # Preserve those native IDs when converging to the dedicated durable home.
    # Credentials/config.json and existing destination sessions are not copied.
    import_legacy_sessions(home, config)

    compatibility = home / '.local/bin/copilot-cici-super-happier'
    compatibility.parent.mkdir(mode=0o700, parents=True, exist_ok=True)
    if compatibility.is_symlink():
        if compatibility.readlink() != launcher:
            print(f'Keeping custom Copilot launcher: {compatibility}', file=sys.stderr)
        return
    if compatibility.exists():
        legacy = (
            '#!/usr/bin/env bash\nset -euo pipefail\n'
            f'exec {home}/.local/bin/copilot --effort=xhigh '
            '--max-autopilot-continues=20 --no-auto-update "$@"\n'
        )
        if compatibility.read_bytes() != legacy.encode():
            print(f'Keeping custom Copilot launcher: {compatibility}', file=sys.stderr)
            return

    # Existing Happier profiles keep their home-based path; the implementation
    # and Copilot binary now follow the image rather than a stale home install.
    fd, temporary = tempfile.mkstemp(prefix='.copilot-launcher-', dir=compatibility.parent)
    os.close(fd)
    try:
        os.unlink(temporary)
        os.symlink(launcher, temporary)
        os.replace(temporary, compatibility)
    finally:
        if os.path.lexists(temporary):
            os.unlink(temporary)


if __name__ == '__main__':
    configure(Path.home(), Path('/opt/worker-copilot-home'),
              Path('/opt/worker-tools/copilot-cici-super-happier'))
