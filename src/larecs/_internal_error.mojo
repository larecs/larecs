from tracy import Zone


@fieldwise_init
struct InternalError(Equatable, ImplicitlyCopyable, Writable):
    """
    Represents an internal error with a variant name and message.
    """

    comptime UNKNOWN = Self(variant_name="UNKNOWN", msg="Unknown error.")
    comptime out_of_locks = Self(
        variant_name="out_of_locks",
        msg="The number of locks exceeds the maximum limit of 256.",
    )
    comptime unbalanced_unlock = Self(
        variant_name="unbalanced_unlock",
        msg=(
            "Unbalanced unlock. Did you close a query that was already"
            " iterated?"
        ),
    )
    comptime ran_out_of_capacity = Self(
        variant_name="ran_out_of_capacity", msg="No more capacity available."
    )
    comptime mutation_of_zero_entity = Self(
        variant_name="mutation_of_zero_entity",
        msg="Attempted to mutate the zero entity.",
    )

    var variant_name: StaticString
    """The variant name of the error."""
    var msg: StaticString
    """The error message."""

    def write_to(self, mut writer: Some[Writer]) -> None:
        """
        Writes the error message to the given writer.

        Args:
            writer: The writer to write to.
        """
        with Zone(
            function_name="InternalError.write_to(mut writer: Some[Writer])"
        ):
            writer.write("InternalError.", self.variant_name, ": ", self.msg)
