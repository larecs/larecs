import larecs as lx
from larecs.test_utils import FlexibleComponent

comptime World = lx.World[
    FlexibleComponent[0],
    FlexibleComponent[1],
    FlexibleComponent[2],
    FlexibleComponent[3],
]


def main() raises:
    var w = World()
    _ = w.storage.add_entities(
        FlexibleComponent[0](x=42.0, y=13.37),
        FlexibleComponent[1](x=42.0, y=13.37),
        FlexibleComponent[2](x=42.0, y=13.37),
        FlexibleComponent[3](x=42.0, y=13.37),
        count=1000,
    )
