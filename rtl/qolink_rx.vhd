----------------------------------------------------------------------------------
-- QOLink receiver (completed)
--
-- Built on the original receiver's structure (header -> payload -> CRC states,
-- header sanity checks, saturating error counter). Changes:
--   * No rx_valid input. The boards share no clock or valid wire, so bytes
--     come from qolink_phy_rx (oversampling) and a frame starts at the SFD byte.
--   * The payload is streamed out one byte at a time (payload_byte +
--     payload_byte_valid) instead of being stored in an 8192-bit register.
--     That register would have cost ~16k flip-flops plus a huge write mux,
--     and could not hold a full 2047-byte payload anyway. The RX FIFO in the
--     XBUS wrapper will store the bytes in block RAM.
--   * The CRC state is finished. It uses the zero-residue check: run the two
--     received CRC bytes through the same CRC; a good frame leaves 0x0000.
--   * Inter-byte timeout: if the sender stops mid-frame, the receiver drops
--     the frame and goes back to hunting instead of hanging.
--
-- Output contract:
--   frame_start        1-cycle pulse when an SFD is seen (use for timestamps)
--   payload_byte_valid 1-cycle pulse per payload byte, in order
--   frame_valid        1-cycle pulse: CRC good. Header outputs are updated
--                      on this pulse and held until the next good frame.
--   frame_error        1-cycle pulse: frame dropped (bad header, bad CRC,
--                      framing error, or timeout). Discard the payload bytes
--                      already delivered for this frame.
--   error_cnt          saturating count of dropped frames
----------------------------------------------------------------------------------
library IEEE;
use IEEE.STD_LOGIC_1164.ALL;
use IEEE.NUMERIC_STD.ALL;
use work.qolink_pkg.all;

entity qolink_rx is
    generic (
        CLKS_PER_BIT : positive := 16;     -- must match the transmitter
        MAX_PAYLOAD  : natural  := 2047    -- bytes; frames claiming more are dropped
    );
    port (
        clk, rst : in std_logic;
        rx_line  : in std_logic;           -- the wire from the transmitter board

        -- header fields of the last good frame
        destinationID : out STD_LOGIC_VECTOR(3 downto 0);
        sourceID      : out STD_LOGIC_VECTOR(3 downto 0);
        priorityClass : out STD_LOGIC_VECTOR(1 downto 0);
        sequence_h    : out STD_LOGIC_VECTOR(7 downto 0);
        payloadLength : out STD_LOGIC_VECTOR(10 downto 0);

        -- payload stream
        payload_byte       : out std_logic_vector(7 downto 0);
        payload_byte_valid : out std_logic;

        -- frame status
        frame_start : out std_logic;
        frame_valid : out std_logic;
        frame_error : out std_logic;
        error_cnt   : out unsigned(15 downto 0)
    );
end qolink_rx;

architecture fsm of qolink_rx is
    type state is (hunt, rx_header, rx_payload, rx_crc);
    signal current_state : state := hunt;

    -- from the PHY
    signal byte_data  : std_logic_vector(7 downto 0);
    signal byte_valid : std_logic;
    signal byte_ferr  : std_logic;

    signal header          : std_logic_vector(31 downto 0) := (others => '0');
    signal c_crc           : std_logic_vector(15 downto 0) := CRC_INIT;
    signal byte_cnt        : integer range 0 to 3 := 0;
    signal bytes_remaining : unsigned(10 downto 0) := (others => '0');

    -- a byte takes ~10 bit times; 20 bit times of silence mid-frame = sender gone
    constant TIMEOUT_CLKS : positive := 20 * CLKS_PER_BIT;
    signal idle_cnt : integer range 0 to TIMEOUT_CLKS := 0;

    signal errors : unsigned(15 downto 0) := (others => '0');

    function sat_inc(u : unsigned(15 downto 0)) return unsigned is
    begin
        if u = x"FFFF" then
            return u;
        else
            return u + 1;
        end if;
    end function;
begin
    phy : entity work.qolink_phy_rx
        generic map (CLKS_PER_BIT => CLKS_PER_BIT)
        port map (
            clk         => clk,
            rst         => rst,
            line_in     => rx_line,
            rx_byte     => byte_data,
            rx_valid    => byte_valid,
            framing_err => byte_ferr
        );

    error_cnt <= errors;

    process(clk)
        variable header_next : std_logic_vector(31 downto 0);
        variable len         : unsigned(10 downto 0);
        variable crc_next    : std_logic_vector(15 downto 0);
    begin
        if rising_edge(clk) then
            payload_byte_valid <= '0';
            frame_start        <= '0';
            frame_valid        <= '0';
            frame_error        <= '0';

            if rst = '1' then
                current_state <= hunt;
                header        <= (others => '0');
                c_crc         <= CRC_INIT;
                byte_cnt      <= 0;
                idle_cnt      <= 0;
                errors        <= (others => '0');
                destinationID <= (others => '0');
                sourceID      <= (others => '0');
                priorityClass <= (others => '0');
                sequence_h    <= (others => '0');
                payloadLength <= (others => '0');
            else
                -- inter-byte timeout (only while inside a frame)
                if current_state = hunt or byte_valid = '1' or byte_ferr = '1' then
                    idle_cnt <= 0;
                elsif idle_cnt = TIMEOUT_CLKS then
                    idle_cnt      <= 0;
                    errors        <= sat_inc(errors);
                    frame_error   <= '1';
                    current_state <= hunt;
                else
                    idle_cnt <= idle_cnt + 1;
                end if;

                if byte_ferr = '1' then
                    -- bad stop bit: only matters if we are inside a frame
                    if current_state /= hunt then
                        errors        <= sat_inc(errors);
                        frame_error   <= '1';
                        current_state <= hunt;
                    end if;

                elsif byte_valid = '1' then
                    crc_next := crc16_byte(c_crc, byte_data);

                    case current_state is
                        when hunt =>
                            if byte_data = QOLINK_SFD then
                                c_crc         <= CRC_INIT;
                                byte_cnt      <= 0;
                                frame_start   <= '1';
                                current_state <= rx_header;
                            end if;

                        when rx_header =>
                            header_next := header(23 downto 0) & byte_data;
                            header      <= header_next;
                            c_crc       <= crc_next;

                            if byte_cnt = 3 then
                                len := unsigned(header_next(13 downto 3));
                                if header_next(2 downto 0) /= "000"
                                   or to_integer(len) > MAX_PAYLOAD then
                                    -- not a believable header: probably a false SFD
                                    errors        <= sat_inc(errors);
                                    frame_error   <= '1';
                                    current_state <= hunt;
                                else
                                    bytes_remaining <= len;
                                    byte_cnt        <= 0;
                                    if len = 0 then
                                        current_state <= rx_crc;
                                    else
                                        current_state <= rx_payload;
                                    end if;
                                end if;
                            else
                                byte_cnt <= byte_cnt + 1;
                            end if;

                        when rx_payload =>
                            payload_byte       <= byte_data;
                            payload_byte_valid <= '1';
                            c_crc              <= crc_next;
                            bytes_remaining    <= bytes_remaining - 1;
                            if bytes_remaining = 1 then
                                byte_cnt      <= 0;
                                current_state <= rx_crc;
                            end if;

                        when rx_crc =>
                            c_crc <= crc_next;
                            if byte_cnt = 0 then
                                byte_cnt <= 1;               -- got CRC high byte
                            else
                                -- got CRC low byte: good frame leaves zero
                                if crc_next = x"0000" then
                                    frame_valid   <= '1';
                                    destinationID <= header(31 downto 28);
                                    sourceID      <= header(27 downto 24);
                                    priorityClass <= header(23 downto 22);
                                    sequence_h    <= header(21 downto 14);
                                    payloadLength <= header(13 downto 3);
                                else
                                    errors      <= sat_inc(errors);
                                    frame_error <= '1';
                                end if;
                                current_state <= hunt;
                            end if;
                    end case;
                end if;
            end if;
        end if;
    end process;
end fsm;
