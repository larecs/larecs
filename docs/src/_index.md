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
versioning unless they are explicitly marked experimental. GPU execution is
currently such an experimental API.

## Features

- Clean and simple API
- High performance due to archetypes and Mojo's compile-time programming
- Support for SIMD via a [`vectorize`](https://docs.modular.com/mojo/stdlib/algorithm/functional/vectorize/)-like syntax
- Compile-time checks thanks to usage of parameters
- Native support for [resources](https://mlange-42.github.io/arche/guide/resources/) and scheduling.
- Tested and benchmarked
- Packaged dependencies are installed automatically
- More features coming soon...
