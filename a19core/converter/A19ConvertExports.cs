using System;
using System.IO;
using System.Linq;
using System.Runtime.InteropServices;
using System.Text;
internal static unsafe class A19ConvertExports {
    static int busy;
    [UnmanagedCallersOnly(EntryPoint="a19_convert_game")]
    public static int ConvertGame(byte* keys,byte* game,byte* docs,byte* bundle,delegate* unmanaged<byte*,void> progress,byte* output,nuint cap){
        if(System.Threading.Interlocked.Exchange(ref busy,1)!=0)return -2;
        string old=Environment.GetEnvironmentVariable("S2A_ROMFS_IMAGE");
        void Say(string s){if(progress==null)return;byte[] b=Encoding.UTF8.GetBytes(s+"\0");fixed(byte* p=b)progress(p);}
        try{
            string d=Marshal.PtrToStringUTF8((nint)docs)!, k=Marshal.PtrToStringUTF8((nint)keys)!, g=Marshal.PtrToStringUTF8((nint)game)!;
            string result=ConvertJob.Run(k,g,d,Marshal.PtrToStringUTF8((nint)bundle)!,Say);
            byte[] data=Encoding.UTF8.GetBytes(result+"\0");
            if((nuint)data.Length>cap)return -3;
            data.AsSpan().CopyTo(new Span<byte>(output,data.Length));return 0;
        }catch(Exception e){Say("Error: "+e.Message);return -1;}
        finally{Environment.SetEnvironmentVariable("S2A_ROMFS_IMAGE",old);}
    }
}
