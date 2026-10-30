# qolink link design notes

Working notes for the qolink point-to-point link: block architecture, credit flow control, framing and encoding, physical layer and receiver alignment, clocking, Cat5e pair allocation, timestamping, latency measurement and time sync, startup sequence. Companion to `qolink_stack.dot` (Graphviz source, render with `dot -Tsvg qolink_stack.dot -o qolink_stack.svg`).

Target hardware for the first iteration: two Zybo Z7-10 boards (Xilinx 7 series, Artix-7 class fabric), regular I/O banks (no GTP transceivers), custom PHY Pmod with LVDS transceivers, RJ45 jacks, Cat5e cable.

---

## 0. Conventions and lexicon

One notation throughout. Every symbol used in this document is listed here.

| Glyph | Spelled name | Meaning |
|---|---|---|
| A, B | endpoint A, endpoint B | The two link endpoints. Hardware is identical; roles are decided at runtime. |
| A→B | A to B | The direction from A towards B. One data pair and one clock pair carry it. |
| t1 | timestamp one | Time at which A's serializer puts the SFD of the probe on the wire, read on A's counter. |
| t2 | timestamp two | Time at which B's deserializer detects the SFD of the probe, read on B's counter. |
| t3 | timestamp three | Time at which B's serializer puts the SFD of the reply on the wire, read on B's counter. |
| t4 | timestamp four | Time at which A's deserializer detects the SFD of the reply, read on A's counter. |
| d | one-way link delay | Time from SFD out at one serializer to SFD in at the other deserializer, same direction. Written d_AB and d_BA when the two directions differ. |
| o | counter offset | B's counter value minus A's counter value at the same physical instant. |
| SFD | start of frame delimiter | The symbol that marks the beginning of a packet on the wire. All hardware timestamps are taken on it. |
| CRC | cyclic redundancy check | Checksum appended to every packet, recomputed and compared by the receiver. |
| IDELAY | input delay primitive | Programmable delay line on each input pin of the 7 series fabric (IDELAYE2). |
| ISERDES | input serializer/deserializer primitive | Input block that samples the pin and groups bits into words (ISERDESE2). |
| OSERDES | output serializer/deserializer primitive | Output block that turns words into a bit stream (OSERDESE2). |
| CDR | clock and data recovery | Extracting the sender's bit timing from the transitions in the data itself. |
| ppm | parts per million | Unit for the frequency difference between two oscillators. 100 ppm means 100 Hz per MHz. |
| ns, ps | nanosecond, picosecond | 1 ns = 1000 ps. |
| Ω | ohm | Unit of impedance. Cat5e pairs are nominally 100 Ω differential. |
| LVDS | low voltage differential signalling | The electrical standard used on each pair. |
| MMCM, BUFIO | mixed-mode clock manager, I/O clock buffer | 7 series clocking primitives used to take a forwarded clock into the fabric. |
| VCXO, DAC | voltage controlled crystal oscillator, digital-to-analog converter | What would be needed to trim an oscillator frequency from logic. Not present on the Zybo, not needed in this design. |
| tick | counter tick | One increment of the timestamp counter. Its duration is the link clock period (example used below: 20 ns). |

Terms used in the text:

- **Credit**: one unit of permission to send. One credit corresponds to one slot in the peer's RX buffer.
- **Class**: a priority level of data traffic. Three classes: high, med, low.
- **Comma**: a special symbol whose bit pattern cannot appear at any other bit offset in a valid stream, used to find word boundaries.
- **Bitslip**: shifting the deserializer's word grouping by one bit.
- **Eye**: the time window inside each bit where the wire value is stable and safe to sample. "Mid-eye" is the centre of that window.
- **Skew** (delay skew): difference in propagation time between two pairs of the same cable.
- **Loop timing**: one endpoint derives its transmit clock from the clock it receives from the peer, so the whole link runs from one oscillator.
- **One-step timestamping**: the transmit timestamp is written into the packet while the packet is going out, as opposed to being sent in a later follow-up packet (two-step).

---

## 1. Architecture

### 1.1 Layers, top to bottom

**Host layer**

- *Measurement applications*: produce and consume packets through API calls.
- *Driver / host interface*: moves packets between the applications and the link hardware. Pushes outgoing packets into one of three TX FIFOs according to class. Pops incoming packets from the RX buffer.

**Transmit path (one per endpoint)**

- *TX FIFO high, med, low*: three queues, one per class.
- *Arbiter / flow control*: picks the next thing to send. Credits first (see section 2), then data by class. A data packet is started only if a credit is available for it.
- *Framer*: wraps a packet for the wire: SFD, header, payload, timestamp field, CRC. Writes the transmit timestamp in flight.
- *Encoder*: maps bytes to line symbols (4b/5b or 8b/10b). Provides control symbols: comma, idle, credit.
- *Serializer (OSERDES)*: turns symbols into a bit stream at the link rate.
- *LVDS driver*: puts the bit stream on the pair.

**Receive path (one per endpoint)**

- *LVDS receiver*: takes the differential signal off the pair.
- *Deserializer (ISERDES + IDELAY)*: samples the bits mid-eye and groups them into words. The IDELAY tap is set by link training and tracked while the link runs.
- *Decoder (+ word align)*: finds commas, bitslips until words are aligned, maps symbols back to bytes, flags invalid symbols, separates control symbols (credit, idle) from data.
- *Deframer*: finds the SFD, captures the receive timestamp, checks length and CRC, extracts credits and hands them to the credit counter, hands good data packets to the RX buffer with their receive timestamp attached, drops bad packets and counts them.
- *RX buffer*: holds received packets until the host pops them.

**Flow control (section 2)**

- *Credit dealer*: counts RX buffer slots freed by the host and hands credits to the transmit side to be sent to the peer.
- *Credit counter*: counts credits received from the peer. Gates the arbiter.

**Timing (section 7 and 8)**

- *Link clock*: on the master, the local oscillator. On the slave, the clock recovered from the peer.
- *Timestamp counter*: 64 bit, free running, clocked by the link clock. Sampled at SFD out and SFD in.

**Physical**

- *RJ45 / Cat5e*: four pairs. Pair 1: clock A→B. Pair 2: data A→B. Pair 3: clock B→A. Pair 4: data B→A.

### 1.2 Blocks missing from the hand drawing

The hand drawing is the right stack but leaves out three blocks a real serial link cannot run without.

**Link training state machine.** At power-up the receiver sees raw bits with unknown phase and unknown word boundaries. Something has to sweep IDELAY to find the eye, search for commas to find word boundaries, decide when the link is trustworthy, and decide when it is no longer trustworthy. Section 4.5 describes it. Without it there is no defined moment at which the link becomes usable, and no recovery when a cable is unplugged, the wire gets noisy, or the peer resets.

**CRC check in the deframer.** Wires flip bits. Without a CRC a flipped bit in a length field or a class field is accepted as truth and every layer above acts on a lie. Section 3.1 describes the check and the interaction with credits.

**Timestamp counter.** The block the latency question is about. A counter that runs continuously at a known rate; when something happens the current value is attached to it. Drawn dashed in the clean diagram because its surroundings (where the taps are, what clocks it) are the design decisions of sections 7 and 8.

---

## 2. Flow control with credits

### 2.1 The basic mechanism

One credit means one free slot in the peer's RX buffer. A slot is sized for the largest packet.

1. At link up each side starts with as many credits as the peer's RX buffer has slots (a fixed number both sides know, or announced during training).
2. Before starting a data packet, the arbiter checks the credit counter. If it is zero the packet waits. If it is nonzero the arbiter decrements the counter and starts the packet.
3. The credit check happens before the packet starts, never in the middle of it. A packet that has started always finishes. A stall mid-packet would hold the framer and the whole transmit path.
4. When the host pops a packet from the RX buffer, one slot is freed. The credit dealer records one credit to return to the peer.
5. The credit is transmitted. On the peer, the deframer extracts it and increments the credit counter.

Two rules follow from this and are easy to get wrong:

- **Credits are issued on drain, not on arrival.** A packet arriving does not free anything. The host popping it does. The arrow into the credit dealer comes from the RX buffer pop.
- **Credits are extracted in the deframer, before the RX buffer.** The deframer feeds the credit counter directly. If credits had to travel through the RX buffer they would sit behind data the host has not popped yet (head of line blocking), and the exact deadlock of section 2.2 would appear one layer down.

### 2.2 The deadlock, worked through

Setup: each RX buffer has 4 slots. Both sides start with 4 credits. Credits are queued in the TX FIFO high, together with high-class data. The arbiter is strict priority and serves the head of the high FIFO first.

What happens when only one host is slow:

1. A's host is busy and stops popping A's RX buffer. Nothing else is wrong.
2. B sends 4 packets to A. A's RX buffer is full. B's credit counter (credits from A) is now 0.
3. B has another high-class packet for A. The arbiter on B puts it at the head of the high FIFO. No credit, so it waits.
4. Meanwhile B's host keeps popping B's RX buffer (A has been sending to B). Each pop produces a credit for A. Those credits are queued into B's high FIFO, behind the waiting data packet.
5. A keeps sending to B. A's credit counter goes 4, 3, 2, 1, 0, because the credits B owes A are stuck behind B's blocked packet.
6. A now has a data packet at the head of its high FIFO waiting for a credit that B cannot send.
7. A's host wakes up and pops everything. The credit dealer on A produces 4 credits for B. They go into A's high FIFO, behind A's blocked data packet.
8. State: B is waiting for credits that sit behind A's blocked packet. A is waiting for credits that sit behind B's blocked packet. Both hosts are idle and have free buffer space. Nothing will ever move again.

The dependency is circular across the two directions: A→B credits ride on the B→A stream, B→A credits ride on the A→B stream. One slow host on one side is enough to start the cycle, and the cycle survives that host recovering.

### 2.3 Why a "high" class is not enough

The problem is not that credits are low priority. It is that they share a queue with something that can block.

- A data packet, whatever its class, can block: it needs a credit, and the credit may never come.
- A credit never blocks: the receiver sinks it into a counter, not a buffer. Incrementing a counter never has to wait for anything.

Putting both in one queue means the thing that never needs to wait is forced to wait behind the thing that can wait forever.

### 2.4 The two fixes

**Option 1, a class above high inside the arbiter.** The arbiter checks "is a credit pending?" before it looks at any data class, and before it looks at whether the current data head has a credit. If a credit is pending, it sends the credit. Credits are small and never gated, so this costs a few symbols of latency on data and nothing else. The credit dealer is a separate input to the arbiter, not an entry in a FIFO shared with data.

**Option 2, a control symbol from the framer.** Credits never enter the arbiter. The framer keeps a "credits to return" counter fed by the credit dealer. Between two packets, or during idle, it emits a dedicated credit symbol carrying that count. The data path does not know credits exist.

Option 2 is cleaner (the arbiter only arbitrates data) and is the natural fit for an 8b/10b or 4b/5b code that has spare control symbols. Either option is fine. What matters is the invariant below.

### 2.5 The invariant

A credit must be sinkable unconditionally on the receiving side. The sink is a plain counter that can always be incremented. If the receiver ever has to buffer credits and can refuse them, the same deadlock reappears one layer down.

### 2.6 Lost credits

A credit symbol or credit packet corrupted on the wire is dropped by the receiver. If credits are sent as deltas ("here are 2 more"), a dropped credit is lost forever and the sender slowly starves.

Fix, cheap and worth doing: send the **cumulative** count of credits issued since link up (modulo the counter width), not the delta. The receiver keeps the last cumulative value it saw, takes the difference, and adds that. A lost credit message is healed by the next one. This is how PCIe does it.

### 2.7 Credits and dropped packets

If the deframer drops a packet (bad CRC, bad length), that packet never took an RX buffer slot. The credit the sender spent on it must still come back, otherwise the sender loses one credit per corrupted packet and starves over time. The credit dealer must therefore be told about drops as well as pops: a drop returns the credit immediately.

### 2.8 Open decision: one RX buffer or one per class

One shared RX buffer means a flood of low-class traffic from A can fill B's RX buffer and block A's high-class traffic behind the credit limit. Priority then only holds inside the sender, not end to end. If priority must hold end to end, give each class its own RX buffer and its own credit pool (three credit counters, three dealers, or one dealer carrying three counts). More logic, cleaner guarantee. Decide based on what the measurement applications need.

---

## 3. Framing and encoding

### 3.1 Packet format on the wire

```
SFD | header (class, length, sequence number) | payload | t_tx | CRC
```

- **SFD**: one control symbol. Every hardware timestamp is taken on its first bit.
- **Header**: class (2 bits are enough for three classes plus one spare), length, sequence number per class for loss detection.
- **Payload**: application data.
- **t_tx**: the transmit timestamp, written in flight (section 7). It comes after the payload so the framer has already started sending when it is captured.
- **CRC**: computed by the framer over header, payload and t_tx as they stream out. Because the CRC is computed on the fly, the timestamp inserted in flight is covered by it. The deframer recomputes over what it received and compares.

On a CRC mismatch the deframer drops the packet, increments an error counter, and returns the credit (section 2.7). A burst of CRC errors is also an input to the link state machine (section 4.5).

### 3.2 Line code

Keep a block code (4b/5b as in 100BASE-X, or 8b/10b as in Gigabit Ethernet, PCIe, SATA) whichever clocking option is chosen. Three reasons:

1. **Transition density.** The code guarantees an edge every few bits. Needed for CDR if the clock is embedded, and still useful for the IDELAY tracking when the clock is forwarded.
2. **DC balance.** 8b/10b keeps the running count of ones and zeros within one bit of equal. LVDS over a long pair without DC balance drifts the baseline and closes the eye. 4b/5b is less well balanced; acceptable for short cables.
3. **Control symbols.** The code reserves symbols that are not data: comma (word alignment), idle (sent when there is nothing to send, also used by the elastic buffer), SFD, credit.

The comma symbol has a bit pattern that cannot appear at any other bit offset in a valid stream, not even across the boundary between two neighbouring symbols. That property is what makes word alignment work (section 4.4). In 8b/10b this is the K28.5 symbol. In 4b/5b the J/K start delimiter plays the role, with weaker guarantees.

Manchester (one edge per bit) also works for clock recovery but halves the data rate for the same bit rate on the wire. Not recommended when a block code gives 80 percent efficiency.

---

## 4. Physical layer and the receiver

### 4.1 Bits on the wire

The sender puts bits on the pair one after another. Each bit lasts a fixed time, the bit period (example: 2 ns for 500 Mbit/s). During that time the pair is either high or low. The change from one bit to the next is not instant and does not land at exactly the same moment every time: it wobbles by a few hundred ps because of noise, cable, and driver. So each bit has a messy start, a clean stable middle, and a messy end.

### 4.2 The eye

Take thousands of bits, cut the wire voltage into slices one bit period long, and draw all the slices on top of each other. Near the start and end of the slice there is a tangle of rising and falling lines crossing: those are the edges, smeared by the wobble. In the middle there is a clean open hole, because in the middle of every bit the wire is firmly high or firmly low. That hole is the eye. Mid-eye is the centre of it.

### 4.3 The receiver's problem and the two ways to solve it

The receiver samples the pair once per bit, on the tick of a clock. Where that tick lands inside the bit is luck: dead centre is perfect, on an edge is garbage. The tick has to be moved into the eye.

**Move the clock (trim).** Nudge the receiver's oscillator frequency and phase until its ticks line up with the sender's bits. Chips that do this have a tunable oscillator built in. The GTP/GTX transceiver pins of an FPGA have one. The ordinary I/O pins of a 7 series device do not. Doing it from the fabric would need a VCXO and a DAC on the board. The Zybo has neither. Do not go down this road.

**Move the data (track phase).** Leave the clock exactly as it is. Delay the incoming signal a little so the eye slides over to where the tick already is. This is what IDELAY is for, and it is the approach for this design.

### 4.4 IDELAY, ISERDES, and the training sweep

**IDELAY** is a tiny adjustable delay line behind each input pin. It has 32 settings, called taps. The tap size depends on the reference clock given to the IDELAYCTRL block: about 78 ps per tap with a 200 MHz reference (total range about 2.5 ns), about 52 ps with 300 MHz. The tap can be changed from logic at any time.

**ISERDES** grabs bits off the pin and groups them into words. It can also take several samples per bit on request, which shows where the value changes.

**The sweep (bit alignment):**

1. At startup the sender transmits a known pattern (commas or a training word).
2. Set IDELAY to tap 0. Check whether the received pattern is correct. Record good or bad.
3. Repeat for tap 1, tap 2, up to tap 31.
4. The result is a strip of good and bad regions. Bad regions are where the tick landed on an edge. Good regions are the eye.
5. Pick the tap in the middle of the longest good region. The tick is now mid-eye.

Two cases where the simple version fails and what to do:

- **The good region is at the edge of the tap range** (starts at tap 0 or ends at tap 31). The centre cannot be found. Fix: the IDELAY range must be larger than one bit period so that at least one complete bad region and one complete good region are always visible. At 2 ns per bit and 2.5 ns of range that holds. At slower bit rates (longer bits) it does not; then either use a faster IDELAYCTRL reference, or also step the ISERDES sampling clock phase through the MMCM fine phase shift, which extends the sweep range.
- **The skew between clock pair and data pair is larger than one bit period.** The sweep then centres the tick in the eye of the wrong bit. This is not an error at this stage: the comma search below moves in whole bits and corrects it.

**Tracking (while the link runs):** as chip and cable warm up or cool down, delays shift by tens of ps and the eye slides. Watch for errors appearing on one side (for example, by periodically testing tap minus one and tap plus one during idle, or by watching the sample history for transitions near the tick) and nudge the tap by one in the other direction.

**Word alignment (bitslip):** the deserializer groups bits N at a time but does not know where a word starts. If the true boundary is 3 bits in from where it thinks, every word is shifted and wrong. The decoder looks for the comma pattern. When the comma appears straddling two words, the decoder issues a bitslip, which shifts the grouping by one bit, and looks again. When the comma lands exactly in one word, the grouping is right. At most N minus 1 bitslips are needed.

### 4.5 Link state machine

| State | What happens | Leaves when |
|---|---|---|
| Reset | No IDELAY tap, no alignment, nothing trusted. Transmit commas. Credits: counter and dealer reset. RX buffer flushed. | Always, after a short settle time. |
| Bit align | Sweep IDELAY, pick mid-eye. | A good region of acceptable width was found. If none, stay here and retry. |
| Word align | Bitslip until commas land in one word. | Comma aligned. |
| Confirm | Count consecutive clean commas with no invalid symbols. | Count reached (for example 64). |
| Link up | Deframer accepts packets. Credits initialised and allowed to flow. Timestamp exchange (section 8) runs. IDELAY tracking active. | Commas stop appearing where expected, invalid symbols or CRC errors exceed a threshold, or the peer signals reset. |
| Link down | Discard everything in flight, flush TX FIFOs or hold them (decision), reset credits, inform the host. | Immediately, back to Reset. |

Both directions train independently. The link is "up" for the host only when both directions are up; each side tells the other its receive status in a control symbol so both agree.

### 4.6 Recovered clock and the elastic buffer

The receive side samples with the sender's rhythm: either the clock on the dedicated pair, or the timing extracted from the data edges. That is the recovered clock. Words come out of the deserializer at the sender's rate.

If the two endpoints run on separate oscillators, that rate differs from the local rate by some ppm. An **elastic buffer** absorbs the difference: a small FIFO between the recovered clock domain and the local clock domain. Words go in at the sender's rate and come out at the local rate. If the sender is slightly faster, the FIFO slowly fills; when it crosses a high mark the receiver deletes one idle symbol. If the sender is slightly slower, the FIFO slowly empties; when it crosses a low mark the receiver repeats one idle symbol. Idles carry no data so nothing is lost. This is how a ppm difference is absorbed without touching an oscillator.

With loop timing (section 5.1) there is only one oscillator in the whole link, both directions run at exactly the same rate, and no elastic buffer is needed. The receive path still crosses from the recovered clock phase to the local clock phase, but that is a fixed phase relationship, handled once by alignment, not a drifting one.

---

## 5. Clocking strategy

### 5.1 Option A, recommended: forwarded clock on its own pair, loop timing

Cat5e has four pairs. Two carry data (A→B, B→A). The other two carry a clock in each direction.

- **No CDR.** The receiver takes the forwarded clock through a BUFIO or an MMCM, uses it to clock the ISERDES, and does the IDELAY sweep once at link up to absorb the pair-to-pair skew and every other fixed offset. This is the standard Xilinx source-synchronous LVDS pattern, documented in the 7 series SelectIO application notes.
- **Loop timing.** The slave derives its transmit clock from the clock it receives from the master. One oscillator for the whole link. Both timestamp counters tick at exactly the same rate. There is no drift at all, only a constant offset between the two counters, measured once at link up (section 8).
- **Latency becomes a constant.** With no elastic buffer and a fixed pipeline, the link delay from SFD out to SFD in does not vary from packet to packet beyond the one-tick quantisation of the counter.

Master/slave is negotiated at link up because the hardware is symmetric: lowest board ID wins, or a jumper, or a register the host sets. The slave switches its transmit clock source from its local oscillator to the recovered clock after its receive side is up. That switch is a clock mux (BUFGMUX) and must be glitch free; the transmit path is held in reset across the switch.

### 5.2 Option B: embedded clock, two oscillators

Data only on the pairs, clock extracted from the data edges by a fabric CDR built from ISERDES oversampling and IDELAY phase tracking. Each endpoint keeps its own oscillator. Needed: the elastic buffer of section 4.6, and the time sync of section 8 run continuously with a frequency correction term on the slave's counter (what a PTP servo loop does). It works, it is the hard version, and it is unnecessary when the cable has four pairs.

### 5.3 What not to do

- **Do not trim frequency.** The 7 series regular I/O cannot do it, and moving the data (IDELAY) is sufficient.
- **Do not let both sides adjust towards each other.** Two control loops chasing each other have no reference and can wander together. One side is the master; the other disciplines itself to it.

---

## 6. Cat5e pairs

### 6.1 What is the same

All four pairs: same wire gauge, same nominal 100 Ω differential impedance, tested to the same limits for loss and crosstalk. For one data stream per pair, a few hundred Mbit/s, a few metres of cable, any pair carries any signal. There is no "good" pair to pick.

### 6.2 What is different: length, therefore delay

The four pairs are twisted at deliberately different rates so they do not couple into each other. A tighter twist uses more copper per metre of cable. The pairs are physically different lengths inside the same jacket, and a signal takes a different time down each one. This is delay skew.

Numbers from the Cat5e standard (TIA-568): propagation delay about 5.5 ns per metre; pair-to-pair skew allowed up to 45 ns per 100 m, so up to 0.45 ns per metre. Real cables usually sit at 15 to 30 ns per 100 m. For a 2 m cable: worst case about 0.9 ns between the slowest and the fastest pair.

Which pair is slowest varies by manufacturer. Never hardcode it.

### 6.3 Where the skew hits the design

- **Clock on one pair, data on another.** The clock arrives a little earlier or later than the data. That is a fixed phase offset. The IDELAY sweep absorbs it with every other offset. If the skew exceeds one bit period, the sweep centres on the wrong bit and the comma search corrects it in whole bits. Nothing extra to build.
- **Two data pairs in parallel to double the rate.** Each pair would need its own IDELAY sweep, its own comma alignment, and then a lane deskew buffer to line the two up. Avoid. The clean allocation is one clock pair and one data pair per direction.
- **Time sync symmetry.** The one-way delay estimate assumes d_AB = d_BA. But A→B is on one pair and B→A on another, and they differ in length. The error on the one-way estimate is half the skew between those two pairs: up to about 0.45 ns on a 2 m cable, in practice less. Against a 20 ns tick that is noise. For sub-nanosecond sync, measure the asymmetry once with a loopback and subtract. Section 8.4 works the numbers.

### 6.4 Lines for the spec

- Cable: Cat5e or better. Maximum length L, chosen now (3 m is comfortable).
- Pair-to-pair skew assumed up to 0.45 ns × L. Everything that depends on it (IDELAY range, symmetry error budget) is sized from that number.
- No assumption about which pair is faster.
- Pair 1: clock A→B. Pair 2: data A→B. Pair 3: clock B→A. Pair 4: data B→A.

---

## 7. Timestamping

### 7.1 Where

In hardware, as close to the wire as possible, on one precise event: the first bit of the SFD.

- **t_tx**: captured when the serializer emits the SFD. The framer writes it into the packet's timestamp field in flight (one-step). This works because the timestamp field comes after the SFD and the framer streams the packet: by the time the field goes out, the value is known. The CRC is computed on the fly over the bytes as they go out, so it covers the inserted stamp.
- **t_rx**: captured when the deserializer detects the SFD. The deframer attaches it as metadata to the packet placed in the RX buffer.

Exact pipeline depths between the capture point and the pin (OSERDES latency, LVDS driver, LVDS receiver, ISERDES latency) are constants. They can be measured once with a loopback and subtracted, or left in and accepted as part of the "link delay" number. Either way they do not vary.

### 7.2 Why not above the serializer

Everything above the serializer has variable delay: queueing in the TX FIFOs, waiting for arbitration, waiting for a credit, framing. Everything from the serializer to the deserializer is fixed pipeline depth plus cable propagation (about 5.5 ns per metre). Stamping at the SFD makes "link latency" a nearly constant number, which is the quantity worth measuring and the quantity whose stability is worth demonstrating.

### 7.3 Optional second stamp: residence time

If the measurement applications want to know how long a packet waited on the host side before reaching the wire, add a stamp taken by the driver when the packet is enqueued. t_tx minus the enqueue stamp is the residence time. This is a separate quantity and must not be mixed with link latency.

### 7.4 The counter

- 64 bit, free running, never reset while the link is up.
- Clocked by the link clock. On the master that is the local oscillator; on the slave, under loop timing, that is the recovered clock, so both counters tick at the same rate.
- Tick duration equals the link clock period. Example used in section 8: 20 ns (50 MHz word clock). Capture resolution is one tick; every measurement below carries plus or minus one tick of quantisation.
- Two capture registers: one strobed by the serializer on SFD out, one strobed by the deserializer on SFD in.
- A settable offset or a settable value, written by the time sync procedure (section 8) on the slave.

---

## 8. Latency measurement and time sync

### 8.1 Why round trip first

One-way latency needs two counters that agree. Round trip does not. Round trip is the baseline, and it produces the counter offset as a by-product.

### 8.2 The exchange

1. A sends a probe. A's serializer captures t1 at SFD out and writes it into the probe.
2. B's deserializer captures t2 at SFD in. B answers immediately, in hardware, with a reply carrying t2 and its own t3 (SFD out, stamped in flight).
3. A's deserializer captures t4 at SFD in. A now holds t1, t2, t3, t4.

Relations, with o the offset of B's counter relative to A's:

- t2 = t1 + d_AB + o
- t4 = t3 + d_BA − o

### 8.3 Formulas

**Round trip on the wire, turnaround removed:**

(t4 − t1) − (t3 − t2) = d_AB + d_BA

Each difference is taken on a single counter: t4 − t1 on A's, t3 − t2 on B's. The offset o cancels. The counters do not need to agree on zero.

**Offset:**

((t2 − t1) + (t3 − t4)) / 2 = o + (d_AB − d_BA) / 2

With symmetric delays the second term is zero and this is exactly o.

**One-way delay, assuming symmetry:**

d = ((t4 − t1) − (t3 − t2)) / 2

### 8.4 Worked examples

Ticks of 20 ns. B's counter happens to be 1,000,000 ticks ahead of A's (o = +1,000,000). B's hardware turnaround is 200 ticks.

**Case 1, symmetric: d_AB = d_BA = 10 ticks.**

- t1 = 5,000
- t2 = 5,000 + 10 + 1,000,000 = 1,005,010
- t3 = 1,005,010 + 200 = 1,005,210
- t4 = 1,005,210 + 10 − 1,000,000 = 5,220

Round trip: (5,220 − 5,000) − (1,005,210 − 1,005,010) = 220 − 200 = 20 ticks. Correct, d_AB + d_BA = 20.

Offset: ((1,005,010 − 5,000) + (1,005,210 − 5,220)) / 2 = (1,000,010 + 999,990) / 2 = 1,000,000. Correct.

One-way: 20 / 2 = 10 ticks = 200 ns. Correct.

**Case 2, asymmetric pairs: d_AB = 10 ticks, d_BA = 12 ticks** (exaggerated: 2 ticks is 40 ns, real skew is under 1 ns, but it shows the arithmetic).

- t1 = 5,000
- t2 = 1,005,010
- t3 = 1,005,210
- t4 = 1,005,210 + 12 − 1,000,000 = 5,222

Round trip: 222 − 200 = 22 ticks. Correct, 10 + 12.

One-way estimate: 11 ticks. True values 10 and 12. Error: 1 tick in each direction, which is half the asymmetry.

Offset estimate: ((1,000,010) + (1,005,210 − 5,222)) / 2 = (1,000,010 + 999,988) / 2 = 999,999. True 1,000,000. Error: 1 tick, half the asymmetry.

So pair skew produces an error of half the skew on both the one-way delay and the offset. For a 2 m cable that is at most 0.45 ns, far under one 20 ns tick. If it ever matters, measure d_AB − d_BA once with a loopback cable and apply it as a correction.

**Case 3, frequency difference during the turnaround** (only exists under option B, two oscillators).

If B's counter runs 100 ppm fast, then during B's 200-tick turnaround B counts 200.02 ticks where A would count 200. The error on the round trip is ppm × turnaround: 100 ppm × 4 µs = 0.4 ns. Sub-tick, and it only exists while the turnaround is in progress. Under loop timing (option A) the frequency difference is zero and this term vanishes exactly. Keep the turnaround in hardware and short regardless; a software reply on B would make the turnaround long and the term larger.

### 8.5 Procedure

1. At link up, run the exchange several times (for example 16). Take the median of the offsets and the median of the round trips. Median rejects an occasional outlier (a corrupted probe, a quantisation extreme).
2. Master writes the offset into the slave's counter (or keeps it as a correction on its own side; pick one and write it down).
3. From then on, t_rx on either side is directly comparable to t_tx from the other side. One-way latency per packet is t_rx − t_tx.
4. Repeat the exchange periodically (for example once per second) as a health check. Under loop timing the offset must not move. If it moves, something is wrong (clock mux fell back, link retrained) and the host is told.

Under option B, step 4 is mandatory and frequent, and the slave applies a frequency correction to its counter derived from how the offset drifts between exchanges.

### 8.6 Quantities and their error budget

| Quantity | How obtained | Error sources |
|---|---|---|
| Round trip delay | Formula 8.3, one exchange | Quantisation, up to 2 ticks. Frequency term (option B only), sub-tick. |
| One-way delay, per direction | Round trip divided by 2 | Above, plus half the pair skew, under 0.5 ns for a few metres. |
| Counter offset | Formula 8.3, median of several | Same as one-way delay. |
| Per-packet one-way latency | t_rx − t_tx after offset applied | Quantisation, up to 1 tick per stamp, plus offset error. |
| Residence time | t_tx − enqueue stamp | Quantisation only; both stamps on the same counter. |

---

## 9. Startup sequence

1. **Link up, both directions.** Both sides transmit commas. Each receiver sweeps IDELAY, picks mid-eye, bitslips until commas align, confirms a run of clean commas. Each side tells the other "my receive side is up" in a control symbol. Link is up when both agree.
2. **Role negotiation.** Master and slave decided (lowest ID, jumper, or host register). The slave holds its transmit path in reset, switches its transmit clock source to the recovered clock (glitch-free mux), releases reset, and the master's receive side re-confirms alignment (the slave's transmit phase may have moved).
3. **Credits.** Both sides load the initial credit count. Credit dealers and counters start from zero issued.
4. **Time sync.** Master runs the four-timestamp exchange, several times, median, writes the offset. Records the round trip as the link delay baseline.
5. **Run.** Data flows. IDELAY tracking active. Periodic exchange as a health check. CRC and invalid-symbol counters monitored; thresholds trip link down, which returns to step 1 and resets credits.

---

## 10. Decisions to fix in the spec

- Bit rate on the wire and the resulting bit period (sizes the IDELAY range check in section 4.4).
- Line code: 8b/10b (better DC balance, well known comma) or 4b/5b (simpler, less balanced).
- Maximum cable length L. Skew budget 0.45 ns × L.
- RX buffer depth in slots and slot size (maximum packet size). Initial credit count equals the depth.
- One shared RX buffer or one per class (section 2.8).
- Credit transport: arbiter class above high, or framer control symbol (section 2.4). Cumulative count either way (section 2.6).
- Master selection rule.
- Timestamp counter clock and tick duration.
- Where the measured offset lives: written into the slave's counter, or kept as a correction on the master.
- Behaviour of the TX FIFOs on link down: flush or hold.
