----------------------------------------------------------------------------------
-- QOLink shared definitions
-- Used by both the transmitter and the receiver so the two sides can never
-- disagree about the start-of-frame byte or the CRC.
----------------------------------------------------------------------------------
library IEEE;
use IEEE.STD_LOGIC_1164.ALL;
use IEEE.NUMERIC_STD.ALL;

package qolink_pkg is
    -- Start-of-frame delimiter, sent before every header. Not included in the CRC.
    constant QOLINK_SFD : std_logic_vector(7 downto 0) := x"D5";

    -- CRC-16/CCITT-FALSE: poly 0x1021, init 0xFFFF, no final XOR, MSB first.
    -- Check value: CRC of ASCII "123456789" = 0x29B1.
    constant CRC_INIT : std_logic_vector(15 downto 0) := x"FFFF";

    -- Advance the CRC by one whole byte (MSB first). Same math as the
    -- original bit-by-bit transmitter, just unrolled 8 times in one clock.
    function crc16_byte(crc_in : std_logic_vector(15 downto 0);
                        data   : std_logic_vector(7 downto 0))
        return std_logic_vector;
end package qolink_pkg;

package body qolink_pkg is
    function crc16_byte(crc_in : std_logic_vector(15 downto 0);
                        data   : std_logic_vector(7 downto 0))
        return std_logic_vector is
        variable c  : std_logic_vector(15 downto 0) := crc_in;
        variable fb : std_logic;
    begin
        for i in 7 downto 0 loop
            fb := c(15) xor data(i);
            c  := c(14 downto 0) & '0';
            if fb = '1' then
                c := c xor x"1021";
            end if;
        end loop;
        return c;
    end function;
end package body qolink_pkg;
