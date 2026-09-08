#!/bin/bash

# Submit script for running Larecs benchmarks on the EVE cluster via SLURM.
#
# This script is self-submitting: run it directly on the login node and it
# parses the flags below, turns them into `sbatch` command-line options
# (since #SBATCH directives can't be made conditional), and resubmits itself
# as the actual job. `#SBATCH` lines below only set the defaults that are
# always safe to request unconditionally; anything conditional is handled by
# the flag parsing further down.
#
# Usage:
#   scripts/eve_submit_benchmarks.sh [options] [-- <args passed to `pixi run benchmarks`>]
#
# Options:
#   --no-gpu           Do not request a GPU node (default: request 1x nvidia-a100)
#   --debug            Submit to the debug partition instead of testing
#   --time=D-HH:MM:SS  Override the job time limit (default: 0-00:15:00)
#   --job-name=NAME    Override the job name (default: larecs-benchmarks)
#   --user=NAME        Cluster username whose /work directory holds the repo
#                       checkout (default: $USER)
#
# Examples:
#   scripts/eve_submit_benchmarks.sh
#   scripts/eve_submit_benchmarks.sh --no-gpu --time=0-01:00:00
#   scripts/eve_submit_benchmarks.sh --testing -- benchmark/query_benchmarks.mojo
#   scripts/eve_submit_benchmarks.sh --user=jdoe

# Job metadata that applies regardless of the flags above
#SBATCH --job-name=larecs-benchmarks
#SBATCH --output=/work/%u/%x-%j.log
#SBATCH --mail-type=ALL

# Request 1G RAM per CPU
#SBATCH --mem-per-cpu=1G

if [ -z "$SLURM_JOB_ID" ]; then
    # --- Submission phase (running on the login node): parse flags, turn
    # them into sbatch options, then resubmit this same script as the job. ---
    GPU=true
    TESTING=false
    TIME=0-00:15:00
    JOB_NAME=
    USERNAME="$USER"

    while [[ $# -gt 0 ]]; do
        case "$1" in
            --no-gpu)
                GPU=false
                shift
                ;;
            --testing)
                TESTING=true
                GPU=false # Testing partitions don't have GPUs
                shift
                ;;
            --time=*)
                TIME="${1#*=}"
                shift
                ;;
            --job-name=*)
                JOB_NAME="${1#*=}"
                shift
                ;;
            --user=*)
                USERNAME="${1#*=}"
                shift
                ;;
            --)
                shift
                break
                ;;
            *)
                echo "Unknown option: $1" >&2
                exit 1
                ;;
        esac
    done

    if [ -z "$USERNAME" ]; then
        echo "No username set: pass --user=NAME or set \$USER" >&2
        exit 1
    fi

    ARGS=(--time="$TIME" --chdir="/work/$USERNAME/larecs")
    $GPU && ARGS+=(-G nvidia-a100:1)
    if $TESTING; then
        ARGS+=(-p testing)
    fi
    [ -n "$JOB_NAME" ] && ARGS+=(--job-name="$JOB_NAME")

    exec sbatch "${ARGS[@]}" "$0" -- "$@"
fi

# --- Execution phase (running on the compute node as the SLURM job) ---

# Drop everything up to and including the "--" the submission phase added,
# leaving only the args meant for `pixi run benchmarks`.
while [[ $# -gt 0 && "$1" != "--" ]]; do
    shift
done
[ "$1" = "--" ] && shift

module load foss/2026b Conda/25.3.1

conda activate pixi

pixi run benchmarks "$@"
