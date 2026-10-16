# Checks whether Mojo rejects a write through a reference after a later
# `mut self` call on the reference's origin. On Mojo 1.0.0 (ed45d567) this
# compiles and prints 5, so a `run` call cannot statically invalidate
# references obtained before it. See decision 0021.
# Run: pixi run mojo run docs/design/research/reference-invalidation-probe.mojo


struct Store:
    var data: List[Int]

    def __init__(out self):
        self.data = [1, 2, 3]

    def get(ref self) -> ref[self.data] List[Int]:
        return self.data

    def run(mut self):
        self.data[0] += 10


def main():
    var s = Store()
    ref x = s.get()
    s.run()
    x[0] = 5
    print(s.data[0])
