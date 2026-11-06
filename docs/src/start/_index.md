+++
type = "docs"
title = "Get started"
weight = -2

[sidebar]
open = true
+++

Build a particle simulation one feature at a time. Each stage is a complete
program in `examples/particles/`.

1. [Install Larecs](../guide/installation): set up the locked environment and
   run the first program.
2. [Your first simulation](first_simulation): move particles with a system and
   a kernel, and check where they end up.
3. [Create and remove particles](growing_simulation): create a batch of
   particles and remove the stationary one.
4. [Share time and configuration](shared_configuration): set the step length
   from a configuration resource before each movement step.

The guides cover each topic in depth:
[entities and components](../guide/data_model),
[systems and kernels](../guide/systems_kernels),
[batch creation and removal](../guide/structural_changes), and
[resources](../guide/shared_resources).
