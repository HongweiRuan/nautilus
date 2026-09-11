#!/usr/bin/env python3
"""Materialize the exact 280-scenario NavSafe full_test set on shared storage."""

from pathlib import Path

from huggingface_hub import HfApi, snapshot_download


REPO_ID = "c13752hz/NavSafe"
ROOT = Path("/avl-west/navsafe_eval")
LEGACY = ROOT / "dataset"
TARGET = ROOT / "full_test"
REFERENCE = ROOT / "metrics_all" / "drivor" / "seed0"


def valid_bundle(path: Path) -> bool:
    return (
        path.is_dir()
        and (path / "manifest.json").is_file()
        and (path / "arrow").is_dir()
        and len(list(path.glob("*.usdz"))) == 4
    )


def main() -> None:
    files = HfApi().list_repo_files(REPO_ID, repo_type="dataset")
    canonical = sorted(
        {
            name.split("/")[1]
            for name in files
            if name.startswith("full_test/") and len(name.split("/")) > 2
        }
    )
    reference = sorted(path.stem for path in REFERENCE.glob("*.json"))
    if len(canonical) != 280 or canonical != reference:
        raise RuntimeError(
            f"authoritative set mismatch: HF={len(canonical)} metrics={len(reference)}"
        )

    TARGET.mkdir(parents=True, exist_ok=True)
    linked = 0
    for token in canonical:
        destination = TARGET / token
        source = LEGACY / token
        if valid_bundle(destination):
            continue
        if not destination.exists() and valid_bundle(source):
            destination.symlink_to(source, target_is_directory=True)
            linked += 1

    missing = [token for token in canonical if not valid_bundle(TARGET / token)]
    print(f"canonical=280 linked_now={linked} need_download={len(missing)}", flush=True)
    if missing:
        snapshot_download(
            REPO_ID,
            repo_type="dataset",
            allow_patterns=[f"full_test/{token}/**" for token in missing],
            local_dir=ROOT,
            max_workers=8,
        )

    invalid = [token for token in canonical if not valid_bundle(TARGET / token)]
    extras = sorted(path.name for path in TARGET.iterdir() if path.name not in canonical)
    if invalid or extras:
        raise RuntimeError(f"full_test validation failed: invalid={invalid} extras={extras}")
    (ROOT / "full_test_tokens.txt").write_text("\n".join(canonical) + "\n")
    print("READY: 280/280 full_test bundles validated", flush=True)


if __name__ == "__main__":
    main()
