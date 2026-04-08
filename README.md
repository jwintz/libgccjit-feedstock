# libgccjit-feedstock

A feedstock for `libgccjit` on macOS ARM64.

## Channel

The package is available on the following channel:
[https://prefix.dev/jwintz](https://prefix.dev/jwintz)

## Installation

```bash
pixi workspace channel add --prepend https://prefix.dev/jwintz
pixi add libgccjit
```

## Build

To build the package locally:

```bash
rattler-build build --recipe recipe/recipe.yaml
```

## Repository

[https://github.com/jwintz/libgccjit-feedstock](https://github.com/jwintz/libgccjit-feedstock)
