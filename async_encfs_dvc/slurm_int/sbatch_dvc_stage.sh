#!/bin/bash -l

#SBATCH --output=output/dvc_sbatch.%x.%j.out
#SBATCH --error=output/dvc_sbatch.%x.%j.err

# to be run with dvc stage add/repro --no-commit --no-lock! (the first SLURM job runs the actual workload, the second one commits it to DVC)

set -euo pipefail

dvc_stage_name="$1"
shift

if [[ "${SLURM_PROCID}" -eq 0 ]]; then
    echo "sbatch_dvc_stage.sh: Clean up of any left-overs from previous run (in case of requeue)"

    dvc_stage_outs=()
    while IFS= read -r out; do
        if [ -n "${out}" ]; then
            dvc_stage_outs+=("${out}")
        fi
    done < <(python3 <<EOF
# dvc_get_stage_outs.py
import yaml

with open("dvc.yaml") as f:
    dvc_yaml = yaml.load(f, Loader=yaml.FullLoader)

print('\n'.join([p for out in dvc_yaml['stages']["${dvc_stage_name}"]['outs']
                   for p in (out if isinstance(out, dict) else [out])]))
EOF
)

    for out in "${dvc_stage_outs[@]}"; do # coordinate outs-persist-handling with dvc_create_stage
        ls -I dvc_stage_out.log  "${out}" | xargs -I {} rm -r "${out}"/{} || true # correct dvc stage add --outs-persist behavior (used to avoid accidentally deleting files of completed, but not committed stages), requires mkdir -p <out_1> <out_2> ... in command
        mkdir -p "${out}" # output deps must be avaiable (as dirs) upon submission for dvc repro --no-commit --no-lock to succeed
    done
fi

set -x
echo "sbatch_dvc_stage.sh: Running DVC stage ${SLURM_JOB_NAME}."
mv "${dvc_stage_name}".dvc_pending "${dvc_stage_name}".dvc_started && fsync "${dvc_stage_name}".dvc_started  # could protect by flock
{{ slurm_stage_env or '' }}
time srun --wait=300 "$@"  # --wait to allow more asymmetric task completion than 30 sec, especially with encfs (TODO: separate srun from sbatch options in dvc_app.yaml)
mv "${dvc_stage_name}".dvc_started "${dvc_stage_name}".dvc_complete && fsync "${dvc_stage_name}".dvc_complete  # could protect by flock

