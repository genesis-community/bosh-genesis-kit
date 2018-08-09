# Improvements

This release adds a `prometheus` UAA client to the BOSH director,
which has the authorities `bosh.read` and the scope `bosh.read`. This
client is to be used by the `prometheus-genesis-kit` for gathering
BOSH metrics.