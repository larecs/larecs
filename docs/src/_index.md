---
title: "Larecs🌲"
type: docs
summary: Larecs🌲 – Lightweight archetype-based ECS for Mojo.
---

## A lightweight archetype-based ECS for Mojo

Larecs🌲 is a performance-oriented archetype-based ECS for [Mojo](https://www.modular.com/mojo)🔥.
Its architecture is based on the Go ECS [Arche](https://github.com/mlange-42/arche).
Larecs 1.0 is currently in beta, so public APIs may still change before the
stable 1.0.0 release. After that release, public APIs follow semantic
versioning unless they are explicitly marked experimental. Device execution is
currently such an experimental API.

To build your first simulation, [install Larecs](guide/installation) and
follow [Your first simulation](start/first_simulation). Two further tutorials
extend the same particles with
[creation and removal](start/growing_simulation) and
[shared configuration](start/shared_configuration).

The guides explain each task in depth:
[entities and components](guide/data_model),
[systems and kernels](guide/systems_kernels),
[batch creation and removal](guide/structural_changes), and
[resources](guide/shared_resources). The [API reference](reference) covers imports and exact contracts.
