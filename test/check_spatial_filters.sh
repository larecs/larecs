#!/usr/bin/env bash
# Verify compile-time rejection at the public classifier registration boundary.
# Run with: pixi run spatial-filter-checks
set -euo pipefail

spatial_repo_root="$(cd "$(dirname "$0")/.." && pwd)"
spatial_check_dir="$(mktemp -d)"
trap 'rm -rf "$spatial_check_dir"' EXIT

check_rejected() {
    local name="$1" filter="$2" accessor_filter="$3" diagnostic="$4"
    cat > "$spatial_check_dir/$name.mojo" <<MOJO
from larecs import World, Filter, SpatialClassifier
from larecs.entity import EntityAccessor

@fieldwise_init
struct Policy(SpatialClassifier):
    comptime Accessor = EntityAccessor[$accessor_filter]
    def classify(self, entity: Self.Accessor) raises -> UInt64:
        return 0

def main() raises:
    var world = World[Int]()
    world.register_spatial_classifier[$filter](Policy())
MOJO
    if mojo build -I "$spatial_repo_root/src" "$spatial_check_dir/$name.mojo" \
        -o "$spatial_check_dir/$name" > "$spatial_check_dir/$name.log" 2>&1; then
        echo "FAIL: $name unexpectedly compiled"
        return 1
    fi
    if ! grep -F "$diagnostic" "$spatial_check_dir/$name.log" >/dev/null; then
        cat "$spatial_check_dir/$name.log"
        echo "FAIL: $name failed without the expected diagnostic"
        return 1
    fi
    echo "PASS: $name"
}

check_rejected writable_include 'Filter().include[Int]()' 'Filter().include[Int]()' 'Spatial classifier filters must be read-only'
check_rejected writable_only 'Filter().write[Int]()' 'Filter().write[Int]()' 'Spatial classifier filters must be read-only'
check_rejected unknown_include 'Filter().read[Float64]()' 'Filter().read[Float64]()' 'Spatial classifier includes an unknown world component'
check_rejected unknown_exclude 'Filter().read[Int]().exclude[Float64]()' 'Filter().read[Int]().exclude[Float64]()' 'Spatial classifier excludes an unknown world component'
check_rejected mismatched_accessor 'Filter().read[Int]()' 'Filter()' 'Classifier Accessor must match its registration filter'
