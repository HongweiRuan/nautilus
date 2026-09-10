from pathlib import Path
import json

root = Path("/avl-west/navsafe_eval/simscale_aug_outputs")
models = [
    "ltf_simscale",
    "gtrs_dense_resnet_expert_simscale",
    "gtrs_dense_resnet_reward_simscale",
    "gtrs_dense_vov_expert_simscale",
    "gtrs_dense_vov_reward_simscale",
]
bad = []
for model in models:
    for seed in ("seed0", "seed1", "seed1024"):
        files = sorted((root / model / seed).glob("*/navsafe_metrics.json"))
        valid = 0
        for path in files:
            try:
                data = json.loads(path.read_text())
                score = data.get("metrics", {}).get("driving_score")
                valid += data.get("status") == "scored" and isinstance(score, (int, float))
            except Exception:
                pass
        ok = len(files) == 280 and valid == 280
        print(model, seed, f"files={len(files)}", f"valid={valid}", "OK" if ok else "INCOMPLETE")
        if not ok:
            bad.append((model, seed, len(files), valid))
raise SystemExit(1 if bad else 0)
