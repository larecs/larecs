#! /usr/bin/env python
import subprocess
from time import perf_counter

import matplotlib.pyplot as plt
from tqdm import tqdm


def execute_one(component_count):
    start_time = perf_counter()

    subprocess.run(["mojo", "-I", "../../src", f"src/compile_{component_count}.mojo"])

    return perf_counter() - start_time


def clean_compilation():
    subprocess.run(["mojo", "--clear-cache", "--force"])


def main():
    component_counts = [
        1,
        2,
        4,
        8,
        16,
        32,
    ]  # 64, 128, 256]
    compile_times = []

    clean_compilation()

    for count in tqdm(component_counts):
        compile_times.append(execute_one(count))

    fig, ax = plt.subplots()
    ax.plot(component_counts, compile_times, "x-")
    ax.set_xlabel("Component Count")
    ax.set_ylabel("Compile Time [s]")
    plt.show()


if __name__ == "__main__":
    main()
