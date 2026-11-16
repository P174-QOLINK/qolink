----------------------------------------------------------------------------------
-- Engineers: Moneeb, Elias  (revised for two-board operation)
-- Module Name: TransmitterBoard
--
-- Same frame and same FSM idea as the original (Idle -> header -> payload ->
-- CRC), with these changes so the receiver on the other board can follow it:
--   1. A start-of-frame byte (QOLINK_SFD = x"D5") goes out before the header.
--   2. Bits now go out through qolink_phy_tx as 8N1 bytes (start/stop bits),
--      so the receiver can re-sync every byte without a clock wire.
--   3. Fixed the payload off-by-one: exactly payloadLength bytes are sent.
--   4. sendTranmission is edge-detected, so holding it high sends one frame.
--   5. Everything is rising-edge, like NEORV32.
--
-- Frame on the wire (each item is one 8N1 byte):
--   SFD | hdr[31:24] | hdr[23:16] | hdr[15:8] | hdr[7:0] | payload x N | CRC hi | CRC lo
-- Header layout is unchanged:
--   dest 31-28 | src 27-24 | class 23-22 | seq 21-14 | length 13-3 | "000" 2-0
-- CRC-16/CCITT-FALSE over the 4 header bytes + payload (same math as before).
--
-- Payload interface (first-word-fall-through, like a FIFO):
--   payloadData must already hold the current byte. When the transmitter takes
--   it, nextBytePayloadData pulses for one cycle; advance to the next byte.
--   All payloadLength bytes must be available before you pulse sendTranmission.
----------------------------------------------------------------------------------
library IEEE;
use IEEE.STD_LOGIC_1164.ALL;
use IEEE.NUMERIC_STD.ALL;
use work.qolink_pkg.all;

entity TransmitterBoard is
    generic (
        CLKS_PER_BIT : positive := 16      -- must match the receiver
    );
    Port (
        clk                    : in  STD_LOGIC;
        reset                  : in  STD_LOGIC;
        sendTranmission        : in  STD_LOGIC;
        transmissionWireBusy   : out STD_LOGIC;
        transmissionWireOutput : out STD_LOGIC;   -- idles high now ('1')

        -- header fields (sampled when the send request arrives)
        destinationID : in  STD_LOGIC_VECTOR(3 downto 0);
        sourceID      : in  STD_LOGIC_VECTOR(3 downto 0);
        priorityClass : in  STD_LOGIC_VECTOR(1 downto 0);
        sequence      : in  STD_LOGIC_VECTOR(7 downto 0);
        payloadLength : in  STD_LOGIC_VECTOR(10 downto 0);

        -- payload, byte by byte
        payloadData         : in  STD_LOGIC_VECTOR(7 downto 0);
        nextBytePayloadData : out STD_LOGIC
    );
end TransmitterBoard;

architecture Behavioral of TransmitterBoard is
    type stateType is (Idle, SendSync, SendHeader, SendPayload, SendCRC);
    signal state : stateType := Idle;

    signal headerReg      : STD_LOGIC_VECTOR(31 downto 0) := (others => '0');
    signal byteIdx        : integer range 0 to 3 := 0;
    signal bytesRemaining : unsigned(10 downto 0) := (others => '0');
    signal CRCReg         : STD_LOGIC_VECTOR(15 downto 0) := CRC_INIT;
    signal sendPrev       : STD_LOGIC := '0';

    -- handshake with the byte serializer
    signal phyStart : STD_LOGIC := '0';
    signal phyByte  : STD_LOGIC_VECTOR(7 downto 0) := (others => '0');
    signal phyDone  : STD_LOGIC;
begin
    phy : entity work.qolink_phy_tx
        generic map (CLKS_PER_BIT => CLKS_PER_BIT)
        port map (
            clk      => clk,
            reset    => reset,
            tx_start => phyStart,
            tx_byte  => phyByte,
            tx_done  => phyDone,
            line_out => transmissionWireOutput
        );

    transmissionWireBusy <= '0' when state = Idle else '1';

    -- Pattern in every state: the byte for that state is already being sent.
    -- When the serializer says it is done, hand it the next byte and move on.
    process(clk)
    begin
        if rising_edge(clk) then
            phyStart            <= '0';
            nextBytePayloadData <= '0';
            sendPrev            <= sendTranmission;

            if reset = '1' then
                state    <= Idle;
                byteIdx  <= 0;
                CRCReg   <= CRC_INIT;
                sendPrev <= '0';
            else
                case state is
                    when Idle =>
                        if sendTranmission = '1' and sendPrev = '0' then
                            headerReg <= destinationID & sourceID & priorityClass
                                         & sequence & payloadLength & "000";
                            bytesRemaining <= unsigned(payloadLength);
                            CRCReg   <= CRC_INIT;
                            phyByte  <= QOLINK_SFD;        -- not part of the CRC
                            phyStart <= '1';
                            state    <= SendSync;
                        end if;

                    when SendSync =>
                        if phyDone = '1' then
                            phyByte   <= headerReg(31 downto 24);
                            phyStart  <= '1';
                            CRCReg    <= crc16_byte(CRCReg, headerReg(31 downto 24));
                            headerReg <= headerReg(23 downto 0) & x"00";
                            byteIdx   <= 0;
                            state     <= SendHeader;
                        end if;

                    when SendHeader =>                    -- byteIdx = header byte in flight
                        if phyDone = '1' then
                            if byteIdx /= 3 then
                                phyByte   <= headerReg(31 downto 24);
                                phyStart  <= '1';
                                CRCReg    <= crc16_byte(CRCReg, headerReg(31 downto 24));
                                headerReg <= headerReg(23 downto 0) & x"00";
                                byteIdx   <= byteIdx + 1;
                            elsif bytesRemaining = 0 then -- empty payload: straight to CRC
                                phyByte  <= CRCReg(15 downto 8);
                                phyStart <= '1';
                                byteIdx  <= 0;
                                state    <= SendCRC;
                            else
                                phyByte  <= payloadData;
                                phyStart <= '1';
                                CRCReg   <= crc16_byte(CRCReg, payloadData);
                                nextBytePayloadData <= '1';
                                bytesRemaining <= bytesRemaining - 1;
                                state    <= SendPayload;
                            end if;
                        end if;

                    when SendPayload =>
                        if phyDone = '1' then
                            if bytesRemaining = 0 then    -- last payload byte just finished
                                phyByte  <= CRCReg(15 downto 8);
                                phyStart <= '1';
                                byteIdx  <= 0;
                                state    <= SendCRC;
                            else
                                phyByte  <= payloadData;
                                phyStart <= '1';
                                CRCReg   <= crc16_byte(CRCReg, payloadData);
                                nextBytePayloadData <= '1';
                                bytesRemaining <= bytesRemaining - 1;
                            end if;
                        end if;

                    when SendCRC =>
                        if phyDone = '1' then
                            if byteIdx = 0 then
                                phyByte  <= CRCReg(7 downto 0);
                                phyStart <= '1';
                                byteIdx  <= 1;
                            else
                                state <= Idle;            -- frame complete
                            end if;
                        end if;
                end case;
            end if;
        end if;
    end process;
end Behavioral;
