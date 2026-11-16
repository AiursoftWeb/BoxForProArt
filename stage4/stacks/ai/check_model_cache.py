"""Offline preflight for the model cache before deploying the AI stack."""
import json
import struct
import sys
from pathlib import Path

import yaml
from huggingface_hub import snapshot_download


def check_weights(snapshot: Path, cache: Path) -> None:
    index = snapshot / "model.safetensors.index.json"
    names = (
        set(json.loads(index.read_text())["weight_map"].values())
        if index.is_file()
        else {"model.safetensors"}
    )
    if not names:
        raise ValueError("Empty weight index")
    for name in names:
        path = (snapshot / name).resolve(strict=True)
        if not path.is_relative_to(cache):
            raise ValueError("Weight file is outside the model cache")
        with path.open("rb") as stream:
            header_size = struct.unpack("<Q", stream.read(8))[0]
            if not 0 < header_size <= 64 * 1024 * 1024:
                raise ValueError("Invalid safetensors header")
            header = json.loads(stream.read(header_size))
        end = max(
            tensor["data_offsets"][1]
            for key, tensor in header.items()
            if key != "__metadata__"
        )
        if path.stat().st_size != 8 + header_size + end:
            raise ValueError("Incomplete weight file")


def main() -> int:
    compose = yaml.safe_load(Path(sys.argv[1]).read_text())
    cache = Path(sys.argv[2]).resolve()
    args = compose["services"]["vllm-server"]["command"]
    draft = json.loads(args[args.index("--speculative-config") + 1])["model"]
    failed = False
    for repo in (args[0], draft):
        try:
            snapshot = Path(snapshot_download(repo, cache_dir=str(cache), local_files_only=True))
            json.loads((snapshot / "config.json").read_text())
            check_weights(snapshot, cache)
            if repo == args[0]:
                tokenizer = json.loads((snapshot / "tokenizer_config.json").read_text())
                json.loads((snapshot / "tokenizer.json").read_text())
                if not (snapshot / "chat_template.jinja").is_file() and not tokenizer.get("chat_template"):
                    raise ValueError("Chat template is missing")
            print(f"Local model cache ready: {repo}")
        except Exception as error:
            failed = True
            print(f"Local model cache missing or incomplete: {repo} ({type(error).__name__})", file=sys.stderr)
    if failed:
        print(
            "The AI stack was not changed. Restore the model cache, or accept the "
            "Hugging Face access conditions and run the login/download command in "
            "stage4/stacks/ai/VLLM_GUIDE.md, then rerun Box deployment. "
            "No Hugging Face token is stored by Box or passed to serving.",
            file=sys.stderr,
        )
    return int(failed)


if __name__ == "__main__":
    raise SystemExit(main())
