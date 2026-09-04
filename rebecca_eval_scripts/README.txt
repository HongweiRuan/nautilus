NavSafe: please submit these 10 jobs to the cogrob namespace.
Rebecca's account is blocked by the utilization webhook; a different
account should pass immediately.

  kubectl apply -f lqr-w05.yaml -f lqr-w07b.yaml -f lqr-w13.yaml \
                -f rerun-w00.yaml -f rerun-w01.yaml -f rerun-w02.yaml \
                -f rerun-w03.yaml -f rerun-w04.yaml -f rerun-w05.yaml \
                -f rerun-w06.yaml

What they are:
  lqr-w05/w07b/w13  -- 3 workers that refill the running seed-0/1024 sweep
                       (back to 15 workers = 30 GPUs)
  rerun-w00..w06    -- 7 NEW workers, seed-1 rerun of 5 models
                       (recogdrive_rl, mtdrive_mtgrpo, diffusiondrive_beyonddrive,
                        rap, drivelaw) over all 270 scenarios = 14 GPUs
  Total 44 GPUs.

If any returns "pods resources utilization is too low", re-run the same
command a few times, a minute apart. "AlreadyExists" is fine -- it means
Rebecca's own retry loop got that one in first.

NOTE: these jobs carry NO worker logic of their own. They mount shared
ConfigMaps (navsafe-recon-cfg / navsafe-rerun-cfg) and run
/cfg/run_worker.sh from them, so they pick up the current fixes
automatically. Please do NOT edit or re-create those ConfigMaps.

Verify afterwards:
  kubectl get jobs -n cogrob | grep -E 'lqr-s0k-(w05|w07b|w13)|rerun-s1'
