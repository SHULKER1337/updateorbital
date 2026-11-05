#!/usr/bin/env python3
"""Package the native mod, without generated compiler files or Minecraft assets."""
import hashlib
import json
import tomllib
import zipfile
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
SOURCE = ROOT / "native"


def build():
    meta = json.loads((SOURCE / "horizon-native.json").read_text())
    bundle = tomllib.loads((SOURCE / "mixins/orbital/horizon-mixin.toml").read_text())
    content = tomllib.loads((SOURCE / "horizon-mod.toml").read_text())
    engine = tomllib.loads((SOURCE / "mixins/orbital/engine/Cargo.toml").read_text())
    assert meta["horizon"] == bundle["compatibility"]["horizon_revision"]
    assert meta["version"] == bundle["mod"]["version"] == content["version"] == engine["package"]["version"]
    out = ROOT / "dist" / "orbital.hnmod"
    out.parent.mkdir(exist_ok=True)
    with zipfile.ZipFile(out, "w", compression=zipfile.ZIP_DEFLATED) as archive:
        for path in sorted(SOURCE.rglob("*")):
            name = path.relative_to(SOURCE)
            if not path.is_file() or any(p in {"target", ".git", "__pycache__"} for p in name.parts):
                continue
            info = zipfile.ZipInfo(name.as_posix(), date_time=(2026, 1, 1, 0, 0, 0))
            info.compress_type = zipfile.ZIP_DEFLATED
            info.external_attr = 0o100644 << 16
            archive.writestr(info, path.read_bytes())
        for name in ("LICENSE", "NOTICE"):
            info = zipfile.ZipInfo(name, date_time=(2026, 1, 1, 0, 0, 0))
            info.compress_type = zipfile.ZIP_DEFLATED
            archive.writestr(info, (ROOT / name).read_bytes())
    digest = hashlib.sha256(out.read_bytes()).hexdigest()
    out.with_suffix(".hnmod.sha256").write_text(f"{digest}  {out.name}\n", encoding="utf-8")
    print(f"Built {out}\nSHA256 {digest}")
    return out


if __name__ == "__main__":
    build()
