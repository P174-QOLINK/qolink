# qolink

The QOLink link: a deterministic point-to-point communication link in VHDL with
an Ada driver. This repo is board independent. Nothing in here names a board or
a pin. Board integration lives in `qolink_<board>` repos, which include this one
as a submodule.

## Layout

```
docs/       QOLINK-DESIGN.md (design notes), qolink_stack.svg
rtl/        qolink_pkg.vhd      shared constants and CRC-16
            qolink_tx.vhd       transmitter framer
            qolink_rx.vhd       receiver deframer
            qolink_phy_rx.vhd   async PHY receiver
tb/         qolink_tx_tb.vhd (stale, see the note at its top)
sim/        simulation run script (none yet)
svd/        qolink.svd, the register map and single source for the driver
sw/qolink/  Ada driver crate (Alire crate name: qolink_generic)
```

## Not yet in this repo

- `rtl/qolink_phy_tx.vhd`: instantiated by `qolink_tx.vhd`, so the transmitter
  does not elaborate without it
- `rtl/qolink_xbus.vhd`: XBUS slave and register file
- a working testbench under `tb/` and a run script under `sim/`
