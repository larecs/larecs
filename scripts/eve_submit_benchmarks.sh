#!/bin/bash

# Submit script for running Larecs benchmarks on the EVE cluster via SLURM

# Job metadata
#SBATCH --job-name=larecs-benchmarks
#SBATCH --chdir=/work/<USERNAME>/larecs
#SBATCH --output=/work/%u/%x-%j.log
#SBATCH --time=0-00:15:00

# Request 1G RAM per CPU
#SBATCH --mem-per-cpu=1G
# Request GPU node (NVIDIA A100)
#SBATCH -G nvidia-a100:1

# Register as test job
#SBATCH -p testing

module load foss/2026b Conda/25.3.1

conda activate pixi

pixi run benchmarks
