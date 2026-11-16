with Qolink_Types; use Qolink_Types;

generic
   with procedure Write_Byte (Value : Byte);
   with function Read_Byte return Byte;
package Qolink_Data is
   procedure Put (Data : Byte) renames Write_Byte;
   function Get return Byte renames Read_Byte;
end Qolink_Data;