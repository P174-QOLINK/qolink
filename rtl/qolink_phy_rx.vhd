----------------------------------------------------------------------------------
-- QOLink PHY receiver: recovers 8N1 serial bytes from the wire using
-- oversampling, so no clock wire is needed between the boards.
--
-- How it stays in sync:
--   * the incoming line goes through a 2-flop synchronizer (it is asynchronous
--     to this board's clock)
--   * the falling edge of each start bit restarts the timing, then every bit
--     is sampled in its middle (CLKS_PER_BIT/2 after the edge, then every
--     CLKS_PER_BIT). Because timing re-locks on every byte, oscillator
--     mismatch only has to stay small over 10 bits, not over a whole frame.
----------------------------------------------------------------------------------
library IEEE;
use IEEE.STD_LOGIC_1164.ALL;

entity qolink_phy_rx is
    generic (
        CLKS_PER_BIT : positive := 16
    );
    port (
        clk         : in  std_logic;
        rst         : in  std_logic;
        line_in     : in  std_logic;                     -- the wire from the other board
        rx_byte     : out std_logic_vector(7 downto 0);
        rx_valid    : out std_logic;                     -- 1-cycle pulse, rx_byte is good
        framing_err : out std_logic                      -- 1-cycle pulse, stop bit was not '1'
    );
end qolink_phy_rx;

architecture rtl of qolink_phy_rx is
    type st_t is (S_IDLE, S_START, S_DATA, S_STOP);
    signal st      : st_t := S_IDLE;
    signal sync1   : std_logic := '1';
    signal sync2   : std_logic := '1';
    signal clk_cnt : integer range 0 to CLKS_PER_BIT - 1 := 0;
    signal bit_idx : integer range 0 to 7 := 0;
    signal shreg   : std_logic_vector(7 downto 0) := (others => '0');

    -- tells Vivado to place the synchronizer flops together and not optimize them
    attribute ASYNC_REG : string;
    attribute ASYNC_REG of sync1 : signal is "TRUE";
    attribute ASYNC_REG of sync2 : signal is "TRUE";
begin
    assert CLKS_PER_BIT >= 4
        report "qolink_phy_rx: CLKS_PER_BIT must be at least 4" severity failure;

    process(clk)
    begin
        if rising_edge(clk) then
            sync1 <= line_in;
            sync2 <= sync1;
            rx_valid    <= '0';
            framing_err <= '0';

            if rst = '1' then
                st      <= S_IDLE;
                clk_cnt <= 0;
                bit_idx <= 0;
            else
                case st is
                    when S_IDLE =>
                        clk_cnt <= 0;
                        if sync2 = '0' then           -- falling edge: start bit begins
                            st <= S_START;
                        end if;

                    when S_START =>                   -- wait to the middle of the start bit
                        if clk_cnt = (CLKS_PER_BIT - 1) / 2 then
                            clk_cnt <= 0;
                            if sync2 = '0' then
                                bit_idx <= 0;
                                st      <= S_DATA;
                            else
                                st <= S_IDLE;         -- glitch, not a real start bit
                            end if;
                        else
                            clk_cnt <= clk_cnt + 1;
                        end if;

                    when S_DATA =>                    -- sample each bit in its middle
                        if clk_cnt = CLKS_PER_BIT - 1 then
                            clk_cnt <= 0;
                            shreg   <= sync2 & shreg(7 downto 1);   -- LSB arrives first
                            if bit_idx = 7 then
                                st <= S_STOP;
                            else
                                bit_idx <= bit_idx + 1;
                            end if;
                        else
                            clk_cnt <= clk_cnt + 1;
                        end if;

                    when S_STOP =>
                        if clk_cnt = CLKS_PER_BIT - 1 then
                            clk_cnt <= 0;
                            if sync2 = '1' then
                                rx_byte  <= shreg;
                                rx_valid <= '1';
                            else
                                framing_err <= '1';
                            end if;
                            st <= S_IDLE;             -- leave mid-stop-bit, ready for next edge
                        else
                            clk_cnt <= clk_cnt + 1;
                        end if;
                end case;
            end if;
        end if;
    end process;
end rtl;
