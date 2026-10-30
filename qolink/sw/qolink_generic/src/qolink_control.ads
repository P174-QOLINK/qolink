generic
   with procedure Enable;
   with procedure Disable;
   with function Is_Tx_Full return Boolean;
   with function Is_Rx_Avail return Boolean;
package Qolink_Control is
   procedure Init renames Enable;
   procedure Stop renames Disable;
   function Tx_Ready return Boolean is (not Is_Tx_Full);
   function Rx_Ready return Boolean renames Is_Rx_Avail;
end Qolink_Control;