-- NOTE: rescued unchanged (apart from entity renames) from gateware branch
-- "andrea". It was written for the older bit-level transmitter and has NOT been
-- updated for the current qolink_tx: the port is now spelled sendTranmission,
-- the line idles high, an SFD is sent first, and bytes go out as 8N1 through
-- qolink_phy_tx. Expect it to need rewriting before it can pass.
----------------------------------------------------------------------------------
-- Company: GMU 
-- Engineer:
-- 
-- Create Date: 10/12/2026 
-- Design Name: 
-- Module Name: qolink_tx_tb - Behavioral
-- Project Name: 
-- Target Devices: MicroNova Mercury2
-- Tool Versions: 
-- Description: 
-- 
----------------------------------------------------------------------------------


library IEEE;
use IEEE.STD_LOGIC_1164.ALL;
--use IEEE.NUMERIC_STD.ALL;



entity qolink_tx_tb is
--  Port ( );
end qolink_tx_tb;

architecture Behavioral of qolink_tx_tb is
    -- INPUT signalS
    signal clk_tb: std_logic:= '0'; --Start clock at 0
    signal rst_tb: std_logic:= '0'; 
    signal sendTransmission_tb: std_logic:= '0';
    -- INPUT HeaderFields
    signal destinationID_tb: STD_LOGIC_VECTOR(3 downto 0) := "0000";
    signal sourceID_tb:  STD_LOGIC_VECTOR(3 downto 0) := "0000";
    signal priorityClass_tb: STD_LOGIC_VECTOR(1 downto 0) := "00";
    signal sequence_tb: STD_LOGIC_VECTOR(7 downto 0) := "00000000";
    signal payloadLength_tb: STD_LOGIC_VECTOR(10 downto 0) := "00000000000";
    -- INPUT payload bound
    signal payloadData_tb: std_logic_vector(7 downto 0) := "00000000";
    
    -- OUTPUT signals
    signal transmissionWireBusy_tb, transmissionWireOutput_tb: std_logic;
    -- OUTPUT payload bound
    signal nextBytePayloadData_tb: std_logic;
    
    --CLK Period for freq: 50 Hz
    constant CLK_PERIOD : time := 20 ns;
    
    --complete header
    signal expectedHeader_tb : std_logic_vector(31 downto 0);

    
    
begin

    --Put header all together
    expectedHeader_tb <= destinationID_tb & sourceID_tb &
                     priorityClass_tb & sequence_tb &
                     payloadLength_tb & "000";
                     
                     
    -- Instantiate Devide Undet Test
    dut: entity work.qolink_tx
        port map(
            clk => clk_tb,
            reset => rst_tb,
            sendTransmission => sendTransmission_tb,
            transmissionWireBusy => transmissionWireBusy_tb,
            transmissionWireOutput => transmissionWireOutput_tb,
            destinationID => destinationID_tb,
            sourceID => sourceID_tb,
            priorityClass => priorityClass_tb,
            sequence => sequence_tb,
            payloadLength => payloadLength_tb,
            payloadData => payloadData_tb,
            nextBytePayloadData => nextBytePayloadData_tb
            );
    clock_signal: Process
    begin
        clk_tb<='0';
        wait for CLK_PERIOD / 2;
        
        clk_tb<='1';
        wait for CLK_PERIOD / 2;
    end process clock_signal;
    
    --test
    stimuli: process
    begin
    
    --------------------------- Test 1: Reset ------------------------------------
    rst_tb <= '1'; --turn reset on 
    sendTransmission_tb <= '0'; --No transmition request

    wait for 40 ns; --wait for response

    assert transmissionWireBusy_tb = '0'
        report "FAIL: Transmitter is busy after reset"
        severity error;

    assert transmissionWireOutput_tb = '0'
        report "FAIL: Output not cleared after reset"
        severity error;

    report "PASS: reset test completed";

    rst_tb <= '0';
    
    
   --------------------------- Test 2: Idle State  ------------------------------------
    
    rst_tb <= '0'; --reset off
    sendTransmission_tb <= '0'; --No transmission request
    
    wait for 60ns; 
    
    assert transmissionWireBusy_tb = '0'
        report "FAIL: Transmitter busy in Idle"
        severity error;

    assert transmissionWireOutput_tb = '0'
        report "FAIL: Transmitter output active in Idle"
        severity error;

    report "PASS: Idle test completed";
    
    --------------------------- Test 3: Test start transmittion  ------------------------------------
    -- TEST 3: Start Transmission

    destinationID_tb <= "0001"; --destination of the package (eg: Device 1)
    sourceID_tb      <= "0010"; --sender identity (eg: Device 2)
    priorityClass_tb <= "10"; -- priority level (eg: High)
    sequence_tb      <= x"05"; -- order number (eg: 5)
    payloadLength_tb <= "00000000001"; --Amount of Payload bytes (eg: 1 byte long)
    payloadData_tb   <= x"41";  -- ASCII 'A'
    
    wait until rising_edge(clk_tb);
    
    sendTransmission_tb <= '1'; --request transmission
    
    wait until falling_edge(clk_tb);
    wait for 1 ns; --extra time for dut to update
    
    assert transmissionWireBusy_tb = '1'
        report "FAIL: Transmitter did not become busy"
        severity error;

    report "PASS: Transmission started";
    
    --Reset sendtransmission status after packet accepted
    wait until rising_edge(clk_tb);
    sendTransmission_tb <= '0';
    
    --------------------------- Test 4: Verify the header   ------------------------------------
    --loop through all bits and check match
    for i in 31 downto 0 loop
    
        wait until falling_edge(clk_tb); --next iteration on falling edge
        wait for 1 ns;
        
        assert transmissionWireOutput_tb = expectedHeader_tb(i)
            report "FAIL: Header bit mismatch at index "
                   & integer'image(i)
            severity error;
    end loop;
    
    --------------------------- Test 5: Verify the payload   ------------------------------------
    
    
    for  i in  7  downto 0 loop
        wait until falling_edge(clk_tb);
        wait for 1 ns;

        assert transmissionWireOutput_tb = payloadData_tb(i)
            report "FAIL: Payload bit mismatch at index "
                   & integer'image(i)
            severity error;
    
    end loop;

    report "PASS: All 32 header bits verified";
    
   -- TEST 5B: Check that no extra payload byte is requested

    assert nextBytePayloadData_tb = '0'
        report "FAIL: Extra payload byte requested!"
        severity error;
    
    report "PASS: Payload length verified";
    
       
    wait;
    
    end process stimuli;
end Behavioral;
