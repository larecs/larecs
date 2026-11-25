@fieldwise_init
struct Position(ImplicitlyCopyable, Movable):
    var x: Float64
    var y: Float64


@fieldwise_init
struct Velocity(ImplicitlyCopyable, Movable):
    var x: Float64
    var y: Float64
