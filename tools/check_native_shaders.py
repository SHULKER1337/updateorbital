#!/usr/bin/env python3
"""Validate the exact embedded native passes, including their native prelude."""
import re
import subprocess
import tempfile
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
BUNDLE = ROOT / "native/mixins/orbital"


def main():
    tool = ROOT / "tools/wgslcheck/target/debug/wgslcheck"
    if tool.with_suffix(".exe").exists():
        tool = tool.with_suffix(".exe")
    prelude = re.search(r'pub const PRELUDE: &str = r###"(.*?)"###;',
                        (BUNDLE / "post.rs").read_text(), re.S).group(1)
    passes = [BUNDLE / "engine/data/shaders/strike.wgsl"]
    passes += sorted((BUNDLE / "engine/data/gen").glob("*.wgsl"))
    with tempfile.TemporaryDirectory() as tmp:
        source = Path(tmp) / "pass.wgsl"
        for shader in passes:
            source.write_text(prelude + shader.read_text(), encoding="utf-8")
            subprocess.run([str(tool), str(source)], check=True)
            print(shader.name, flush=True)
    print(f"Validated {len(passes)} native passes")


if __name__ == "__main__":
    main()
