using System;
using System.IO;
using System.Linq;
using System.Buffers.Binary;
using System.Collections.Generic;
class ImageTest {
  static void Main(){
    var root=Path.Combine(Path.GetTempPath(),"a19-img-"+Guid.NewGuid().ToString("N"));Directory.CreateDirectory(root);
    try {
      byte[] rom=new byte[80+24+8*1024*1024+123];
      void Q(int n,ulong v)=>BinaryPrimitives.WriteUInt64LittleEndian(rom.AsSpan(n,8),v);
      Q(0,80);Q(24,80);Q(32,24);Q(56,104);Q(64,0);Q(72,104);
      for(int n=0;n<6;n++)BinaryPrimitives.WriteUInt32LittleEndian(rom.AsSpan(80+n*4,4),n==5?0u:uint.MaxValue);
      new Random(19).NextBytes(rom.AsSpan(104));
      string old=Path.Combine(root,"old.std"),pref=Path.Combine(root,"pref.std"),npdm=Path.Combine(root,"npdm");
      File.WriteAllBytes(old,rom);File.WriteAllBytes(npdm,new byte[]{1,2,3,4});
      using(var f=File.Create(pref)){f.Position=0x4000;f.Write(rom);}
      var extras=new List<(string rel,string path)>{("exefs/main.npdm",npdm)};
      var a=ConverterFormats.RomNames(old);var b=ConverterFormats.RomNames(pref,0x4000);
      if(!a.SequenceEqual(b))throw new Exception("RomFS index differs");
      string x=Path.Combine(root,"old.img"),y=Path.Combine(root,"new.img");
      var p=ConverterFormats.Image(old,x,"0100000000000001",extras,a);
      var q=ConverterFormats.Image(pref,y,"0100000000000001",extras,b,0x4000,ConverterFormats.Sha(rom));
      if(p!=q||ConverterFormats.Sha(x)!=ConverterFormats.Sha(y))throw new Exception("IMG bytes differ");
      Console.WriteLine("Prefixed RomFS and legacy path produce identical IMG bytes and SHA256");
    } finally {Directory.Delete(root,true);}
  }
}
