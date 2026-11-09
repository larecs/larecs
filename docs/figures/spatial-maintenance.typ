// Adapted from thesis.typ sec-spatial-proximity-optimizations and figs.typ
// spatial-ordering/spatial-grouping. Dirty full identities precede movement planning.
#import "_style.typ": *
#diagram({
  panel(0, 0, 3.7, 1.8, [Input writes], [Mutable inputs\ declared writes\ enqueue identities])
  panel(4.8, 0, 3.3, 1.8, [Dirty state], [Unique ID/generation\ structure → full\ retain old keys], paint: colors.output)
  panel(9.1, 0, 3.3, 1.8, [Explicit boundary], [Unlocked storage\ clean → return\ explicit only])
  arrow((3.7, -.9), (4.8, -.9))
  arrow((8.1, -.9), (9.1, -.9))
  panel(0, -3.0, 5.7, 1.9, [Classify and plan],
    [Final inputs → pending keys\ all callbacks before movement\ default: prepare permutations])
  panel(6.7, -3.0, 5.7, 1.9, [Move and commit],
    [Permute rows / place in stores\ all columns + IDs; repair locations\ commit keys, clear dirty state], paint: colors.cluster)
  arrow((10.75, -1.8), (2.85, -3.0))
  arrow((5.7, -3.95), (6.7, -3.95))
  panel(0, -6.0, 5.7, 1.3, [Classifier error], [Rows and old keys unchanged\ dirty work retained], paint: colors.output)
  arrow((2.85, -4.9), (2.85, -6.0))
  label((9.55, -6.65), [Allocation failure is fatal;\ no general rollback transaction.], size: 8.5pt)
})
