#!/usr/bin/env bash

if [ "$#" -ne 1 ]; then
    echo "Usage: slurm_wait_for_job.sh JOBID"
    exit 1
fi

# ID of job to wait for
jobid=$1
echo "Monitoring SLURM job ${jobid}."
sleep 30

while true; do
    job_stage=$(sacct -j $jobid --format=State --noheader | head -1 | awk '{print $1}')

    case "$job_stage" in
    "PENDING"|"RUNNING")
        echo "The SLURM pipeline is still in process."
        dvc_scontrol show stage,commit
        sleep 60
        ;;
    "COMPLETED")
        echo "The SLURM pipeline has successfully completed."
        break
        ;;
    *)
        echo "The SLURM pipeline has failed."
        dvc_scontrol show all
        exit 1
        ;;
    esac
done
