#!/usr/bin/env python3
"""
Aggregate *_summary.csv per model.
For each model, walks all splits/variants/scenarios, collects the summary CSV
from each sd_* dir, and averages numeric columns across all scenarios.

Directory structure:
    zero_shot_results/{model}/{split}/{variant}/sd_*/*_summary.csv

Usage:
    python aggregate_model_results.py                           # all models
    python aggregate_model_results.py --model diffusiondrive    # single model
    python aggregate_model_results.py --plot                    # plot final_score vs rr
"""

import os
import re
import argparse
import pandas as pd
import matplotlib
matplotlib.use("Agg")
import matplotlib.pyplot as plt
from pathlib import Path
from tqdm import tqdm

BASE_PATH = Path("/closed-loop-e2e/experiments/zero_shot_results")


def collect_summary_csvs(model_dir: Path):
    """Walk model_dir and return list of *_summary.csv paths."""
    print(f"  Scanning {model_dir} ...")
    summary_files = []
    for root, _dirs, files in os.walk(model_dir):
        for f in files:
            if f.endswith("_summary.csv"):
                summary_files.append(os.path.join(root, f))
    return summary_files


def average_csvs(csv_paths):
    """Read all CSVs, concat, and return mean of numeric columns as a single-row DataFrame."""
    if not csv_paths:
        return None
    dfs = []
    for p in tqdm(csv_paths, desc="  Reading CSVs", unit="file"):
        try:
            dfs.append(pd.read_csv(p))
        except Exception as e:
            print(f"  Warning: skip {p}: {e}")
    if not dfs:
        return None
    combined = pd.concat(dfs, ignore_index=True)
    numeric_cols = combined.select_dtypes(include="number").columns.tolist()
    return combined[numeric_cols].mean().to_frame().T


def aggregate_model(model_name, base=BASE_PATH):
    """Aggregate summary CSVs for one model. Returns a single-row DataFrame or None."""
    model_dir = base / model_name
    if not model_dir.is_dir():
        print(f"Model dir not found: {model_dir}")
        return None

    summary_files = collect_summary_csvs(model_dir)
    print(f"{model_name}: {len(summary_files)} summary CSVs")

    avg = average_csvs(summary_files)
    if avg is not None:
        avg.insert(0, "model", model_name)
        avg.insert(1, "num_scenarios", len(summary_files))
    return avg


def aggregate_all(models=None, base=BASE_PATH):
    """Aggregate all (or specified) models, print and save combined CSV."""
    if models is None:
        models = sorted(
            d for d in os.listdir(base)
            if (base / d).is_dir()
            and not d.startswith("split_")
            and d not in ("venv", "aggregated_results")
        )

    frames = []
    for m in models:
        avg = aggregate_model(m, base)
        if avg is not None:
            frames.append(avg)

    if not frames:
        print("No results found.")
        return

    out_dir = base / "aggregated_results"
    out_dir.mkdir(exist_ok=True)

    df = pd.concat(frames, ignore_index=True)
    out_path = out_dir / "all_models_summary_avg.csv"
    df.to_csv(out_path, index=False)
    print(f"\nSaved: {out_path}")
    print(df.to_string(index=False))


def extract_rr(path_str):
    """Extract the rr value from a path containing split_*_rr_{value}_ef_*."""
    m = re.search(r"_rr_(\d+)_", path_str)
    return int(m.group(1)) if m else None


def collect_rr_scores(model_name, base=BASE_PATH):
    """Collect final_score grouped by rr value for one model.

    Returns a dict {rr_value: [list of final_scores]}.
    ef and split are merged (averaged together).
    """
    model_dir = base / model_name
    if not model_dir.is_dir():
        return {}

    rr_scores = {}
    count = 0
    pbar = tqdm(desc=f"  {model_name} CSVs", unit="file")
    for root, _dirs, files in os.walk(model_dir):
        for f in files:
            if not f.endswith("_summary.csv"):
                continue
            full_path = os.path.join(root, f)
            rr = extract_rr(full_path)
            if rr is None:
                continue
            try:
                df = pd.read_csv(full_path)
                if "final_score" in df.columns:
                    rr_scores.setdefault(rr, []).extend(df["final_score"].dropna().tolist())
            except Exception:
                pass
            count += 1
            pbar.update(1)
    pbar.close()
    print(f"  {model_name}: processed {count} files")
    return rr_scores


def plot_all_models(models=None, base=BASE_PATH):
    """Plot final_score vs rr for each model (one curve per model)."""
    if models is None:
        models = sorted(
            d for d in os.listdir(base)
            if (base / d).is_dir()
            and not d.startswith("split_")
            and d not in ("venv", "aggregated_results")
        )

    fig, ax = plt.subplots(figsize=(10, 6))

    all_rr_vals = set()
    for model_name in models:
        rr_scores = collect_rr_scores(model_name, base)
        if not rr_scores:
            print(f"{model_name}: no data, skipping")
            continue

        rr_vals = sorted(rr_scores.keys())
        all_rr_vals.update(rr_vals)
        mean_scores = [sum(rr_scores[rr]) / len(rr_scores[rr]) for rr in rr_vals]
        ax.plot(rr_vals, mean_scores, marker="o", label=model_name)
        print(f"{model_name}: {len(rr_vals)} rr values")

    ax.set_xlabel("Replan Rate (rr)")
    ax.set_ylabel("Final Score")
    if len(models) == 1:
        ax.set_title(f"Final Score vs Replan Rate — {models[0]}")
    else:
        ax.set_title("Final Score vs Replan Rate")
    ax.legend()
    ax.grid(True, alpha=0.3)
    if all_rr_vals:
        ax.set_xticks(sorted(all_rr_vals))

    out_dir = base / "aggregated_results"
    out_dir.mkdir(exist_ok=True)
    suffix = f"_{models[0]}" if len(models) == 1 else ""
    out_path = out_dir / f"final_score_vs_rr{suffix}.png"
    fig.savefig(out_path, dpi=150, bbox_inches="tight")
    print(f"\nPlot saved: {out_path}")
    plt.close(fig)


def main():
    parser = argparse.ArgumentParser(description="Aggregate model evaluation results")
    parser.add_argument("--model", type=str, help="Single model name to aggregate")
    parser.add_argument("--base", type=str, default=str(BASE_PATH))
    parser.add_argument("--plot", action="store_true", help="Plot final_score vs rr curves")
    args = parser.parse_args()

    base = Path(args.base)
    models = [args.model] if args.model else None

    if args.plot:
        plot_all_models(models, base)
    else:
        aggregate_all(models, base)


if __name__ == "__main__":
    main()
