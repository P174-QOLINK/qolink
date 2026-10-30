with Qolink_Types; use Qolink_Types;
with Qolink_Control;
with Qolink_Data;

generic
   with package Control is new Qolink_Control (<>);
   with package Data is new Qolink_Data (<>);
package Qolink_Interface is
   procedure Send_ByteBlocking (B : Byte);
   procedure Receive_ByteBlocking (B : out Byte);
end Qolink_Interface;