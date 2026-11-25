// Minimal iOS port of the S2Arm v0.6.10 image and program-pack formats.
// Derived from upstream ios/embed.py, ios/macho_dylib.py, pack/img.py.
// Upstream: https://github.com/jhaizhou-ops/S2Arm/tree/v0.6.10 (Apache-2.0).
using System;
using System.IO;
using System.Linq;
using System.Text;
using System.Collections.Generic;
using System.Security.Cryptography;
using System.Buffers.Binary;
using System.Globalization;

internal static class ConverterFormats {
    const long Page=0x4000;
    static long Up(long n,long a=Page)=>checked((n+a-1)/a*a);
    static void Need(bool ok,string why){if(!ok)throw new InvalidDataException(why);}
    static uint U32(long v)=>checked((uint)v);
    static byte[] B(Action<BinaryWriter> action){using var m=new MemoryStream();using(var w=new BinaryWriter(m,Encoding.UTF8,true))action(w);return m.ToArray();}
    static void Q(BinaryWriter w,long v)=>w.Write(checked((ulong)v));
    static void Fixed(BinaryWriter w,string s,int n){var b=Encoding.UTF8.GetBytes(s);Need(b.Length<=n,"Nombre demasiado largo");w.Write(b);w.Write(new byte[n-b.Length]);}
    static void BE(BinaryWriter w,uint v)=>w.Write(BinaryPrimitives.ReverseEndianness(v));
    static void BE64(BinaryWriter w,long v)=>w.Write(BinaryPrimitives.ReverseEndianness(checked((ulong)v)));
    static void Zeros(FileStream f,long n){Need(n>=0,"Desplazamiento inválido");if(n==0)return;f.Seek(n,SeekOrigin.Current);if(f.Position>f.Length)f.SetLength(f.Position);}
    static void Copy(FileStream src,Stream dst,long bytes,IncrementalHash hash=null){var buf=new byte[4*1024*1024];while(bytes>0){int want=(int)Math.Min(bytes,buf.Length);src.ReadExactly(buf.AsSpan(0,want));dst.Write(buf,0,want);hash?.AppendData(buf,0,want);bytes-=want;}}
    static string Hex(byte[] b)=>Convert.ToHexString(b).ToLowerInvariant();
    internal static string Sha(string path){using var f=File.OpenRead(path);return Hex(SHA256.HashData(f));}
    internal static string Sha(byte[] data)=>Hex(SHA256.HashData(data));
    record Block(string Path,long Offset,long Read,long Pre,long Length,byte[] Bytes=null);
    record Sec(string Name,long At,long Size,uint Align,uint Flags,List<Block> Blocks);
    static long ParseHex(string s){bool neg=s.StartsWith('-');if(neg)s=s[1..];if(s.StartsWith("0x",StringComparison.OrdinalIgnoreCase))s=s[2..];long v=long.Parse(s,NumberStyles.AllowHexSpecifier,CultureInfo.InvariantCulture);return neg?-v:v;}
    static byte[] Segment(string name,long at,long size,long fileSize,uint prot,params Sec[] secs)=>B(w=>{w.Write(0x19u);w.Write((uint)(72+80*secs.Length));Fixed(w,name,16);Q(w,at);Q(w,size);Q(w,at);Q(w,fileSize);w.Write(prot);w.Write(prot);w.Write((uint)secs.Length);w.Write(0u);foreach(var s in secs){Fixed(w,s.Name,16);Fixed(w,name,16);Q(w,s.At);Q(w,s.Size);w.Write(U32(s.At));w.Write(s.Align);w.Write(0u);w.Write(0u);w.Write(s.Flags);w.Write(0u);w.Write(0u);w.Write(0u);}});
    static void WriteBlock(FileStream f,Block b,IncrementalHash body){
        void Pad(long n){if(n==0)return;body.AppendData(B(w=>Q(w,n)));Zeros(f,n);}
        Pad(b.Pre);
        if(b.Bytes!=null){f.Write(b.Bytes);body.AppendData(b.Bytes);}else if(b.Read>0){using var src=File.OpenRead(b.Path);src.Position=b.Offset;Copy(src,f,b.Read,body);}
        Pad(b.Length-b.Pre-b.Read);
    }
    // Exact segment layout, reserved signature space, and linker-style ad-hoc CodeDirectory.
    // The actual team signature must be supplied by the unmodified S2Arm player.
    internal static void Dylib(string root,string dst,IReadOnlyList<string> mods){
        var code=new List<Block>();var data=new List<Block>();long co=0,da=0;
        var idx=B(w=>{Fixed(w,"S2AEMB01",8);w.Write((uint)mods.Count);w.Write(88u);
            foreach(var n in mods){Need(Encoding.UTF8.GetByteCount(n)<=23,"Módulo demasiado largo");var h=new Dictionary<string,long>();
                foreach(var l in File.ReadLines(Path.Combine(root,n+".fixups.tsv"))){if(!l.StartsWith("# "))continue;var p=l[2..].Split((char[])null,2,StringSplitOptions.RemoveEmptyEntries);if(p.Length!=2)continue;if(new[]{"TEXT_END","PATCH_OFF","KEY_PAGE_OFF","KEY_PAGE_SIZE","LOAD_BIAS","PATCH2_LEN","PATCH2_OFF","FILE_IMAGE_LEN"}.Contains(p[0]))h[p[0]]=ParseHex(p[1].Trim());}
                long te=h["TEXT_END"],po=h["PATCH_OFF"],ko=h["KEY_PAGE_OFF"],ks=h["KEY_PAGE_SIZE"],lb=h.GetValueOrDefault("LOAD_BIAS"),l2=h.ContainsKey("PATCH2_OFF")?h.GetValueOrDefault("PATCH2_LEN"):0;
                var path=Path.Combine(root,n+".patched.bin");long full=new FileInfo(path).Length,sz=full-l2,a=Up(te+lb)-lb,end=po>=0?po+Up(sz-po):Up(sz);
                Need(l2>=0&&l2<=full&&l2%4==0,"Segundo parche inválido");long fl=po<0?h["FILE_IMAGE_LEN"]:po;
                Need(ks==Page&&a>=0&&a<=fl&&fl<=sz,"Layout NSO inválido");
                if(po<0)Need(fl%Page==0&&fl<sz&&lb==0,"Layout FAR inválido");else Need((po+lb)%Page==0&&a<=ko&&ko+ks<=po&&(ko+lb)%Page==0,"Key page inválida");
                var es=new (long off,long len)[4];
                void Cut(int kind,long lo,long hi){long fill=Math.Min(hi,kind==3?full:sz)-lo,pre=lb!=0&&lo==0?lb:0,ln=pre+hi-lo;Need(ln>=0&&ln%Page==0&&fill>=0&&fill<=hi-lo,"Corte inválido");var block=new Block(path,lo,fill,pre,ln);if(kind==1){es[kind]=(da,ln);data.Add(block);da+=ln;}else{es[kind]=(co,ln);code.Add(block);co+=ln;}}
                Cut(0,0,a);Cut(1,a,fl);Cut(2,fl,end);if(l2!=0)Cut(3,sz,sz+Up(l2));
                Fixed(w,n,24);foreach(var (off,len) in es){Q(w,off);Q(w,len);}
            }});
        if(da==0){data.Add(new Block(null,0,0,0,Page));da=Page;}
        long ca=Page,ia=Up(ca+co,8),ts=Up(ia+idx.Length),ds=Up(da),le=ts+ds,cs=Up(le+8,16),reserve=Up((cs/4096+1)*52,4096)+0x40000;
        var s1=new Sec("__swcode",ca,co,14,0x80000400,code);var s2=new Sec("__swidx",ia,idx.Length,3,0,new(){new Block(null,0,idx.Length,0,idx.Length,idx)});var s3=new Sec("__img",ts,da,14,0,data);
        var cmds=new List<byte[]>{Segment("__TEXT",0,ts,ts,5,s1,s2),Segment("__SWDATA",ts,ds,ds,3,s3),Segment("__LINKEDIT",le,Up(cs+reserve-le),cs+reserve-le,1)};
        var name=Encoding.ASCII.GetBytes("@rpath/S2AImages.dylib\0");int idz=(int)Up(24+name.Length,8);
        cmds.Add(B(w=>{w.Write(13u);w.Write((uint)idz);w.Write(24u);w.Write(2u);w.Write(0x10000u);w.Write(0x10000u);w.Write(name);w.Write(new byte[idz-24-name.Length]);}));
        long uuidAt=32+cmds.Sum(x=>x.Length)+8;
        cmds.Add(B(w=>{w.Write(27u);w.Write(24u);w.Write(new byte[16]);}));
        cmds.Add(B(w=>{w.Write(0x32u);w.Write(24u);w.Write(2u);w.Write(0x120000u);w.Write(0x120000u);w.Write(0u);}));
        cmds.Add(B(w=>{w.Write(2u);w.Write(24u);w.Write(0u);w.Write(0u);w.Write(U32(le));w.Write(8u);}));
        cmds.Add(B(w=>{w.Write(11u);w.Write(80u);w.Write(new byte[72]);}));
        cmds.Add(B(w=>{w.Write(0x1du);w.Write(16u);w.Write(U32(cs));w.Write(U32(reserve));}));
        int cmdSize=cmds.Sum(x=>x.Length);Need(32+cmdSize<=Page,"Cabecera Mach-O demasiado larga");
        using var f=new FileStream(dst,FileMode.CreateNew,FileAccess.ReadWrite);using var body=IncrementalHash.CreateHash(HashAlgorithmName.SHA256);
        f.Write(B(w=>{w.Write(0xfeedfacfu);w.Write(0x0100000cu);w.Write(0u);w.Write(6u);w.Write((uint)cmds.Count);w.Write((uint)cmdSize);w.Write(0x100085u);w.Write(0u);}));foreach(var c in cmds)f.Write(c);
        foreach(var s in new[]{s1,s2,s3}){Zeros(f,s.At-f.Position);body.AppendData(B(w=>{Q(w,s.At);Q(w,s.Size);}));foreach(var b in s.Blocks)WriteBlock(f,b,body);Need(f.Position==s.At+s.Size,"Longitud sección inválida");}
        Zeros(f,le-f.Position);f.Write(new byte[]{32,0,0,0,0,0,0,0});Zeros(f,cs-f.Position);f.Position=uuidAt;f.Write(body.GetHashAndReset().AsSpan(0,16));
        var ident=Encoding.ASCII.GetBytes("S2AImages\0");uint np=U32((cs+4095)/4096),cdlen=checked(88u+(uint)ident.Length+32*np);
        // CodeDirectory header is 88 bytes (version 0x20400), big endian.
        var sig=B(w=>{BE(w,0xfade0cc0);BE(w,20+cdlen);BE(w,1);BE(w,0);BE(w,20);BE(w,0xfade0c02);BE(w,cdlen);BE(w,0x20400);BE(w,0x20002);BE(w,88+(uint)ident.Length);BE(w,88);BE(w,0);BE(w,np);BE(w,U32(cs));w.Write((byte)32);w.Write((byte)2);w.Write((byte)0);w.Write((byte)12);for(int i=0;i<4;i++)BE(w,0);BE64(w,0);BE64(w,0);BE64(w,ts);BE64(w,0);w.Write(ident);});
        Need(sig.Length==20+88+ident.Length&&20L+cdlen<=reserve,"Firma reservada inválida");f.Position=cs;f.Write(sig);byte[] pg=new byte[4096];for(uint i=0;i<np;i++){long at=i*4096L;int n=(int)Math.Min(4096,cs-at);f.Position=at;f.ReadExactly(pg.AsSpan(0,n));var sha=SHA256.HashData(pg.AsSpan(0,n));f.Position=cs+sig.Length+32L*i;f.Write(sha);}f.SetLength(cs+reserve);
    }
    static uint D32(byte[] b,int i)=>BinaryPrimitives.ReadUInt32LittleEndian(b.AsSpan(i,4));
    static long D64(byte[] b,int i)=>checked((long)BinaryPrimitives.ReadUInt64LittleEndian(b.AsSpan(i,8)));
    internal static List<string> RomNames(string path,long prefix=0){using var f=File.OpenRead(path);Need(prefix>=0&&prefix<=f.Length-80,"RomFS truncada");long length=f.Length-prefix;f.Position=prefix;var hdr=new byte[80];f.ReadExactly(hdr);Need(D64(hdr,0)==80,"RomFS inválida");
        byte[] Meta(long off,long len){Need(off>=0&&len>=0&&len<=256L*1024*1024&&off<=length-len,"Metadatos RomFS inválidos");var b=new byte[(int)len];f.Position=checked(prefix+off);f.ReadExactly(b);return b;}
        var dirs=Meta(D64(hdr,24),D64(hdr,32));var files=Meta(D64(hdr,56),D64(hdr,64));long data=D64(hdr,72);var seenD=new HashSet<uint>();var seenF=new HashSet<uint>();var names=new List<string>();var todo=new Stack<(uint,string)>();todo.Push((0,""));
        string Name(byte[] b,int at,int size){Need(at>=0&&size>=0&&at<=b.Length-size,"Nombre RomFS inválido");var s=new UTF8Encoding(false,true).GetString(b,at,size);Need(!s.Contains('/')&&!s.Contains('\\')&&!s.Contains('\n')&&!s.Contains('\r')&&s!="."&&s!="..","Ruta RomFS inválida");return s;}
        while(todo.Count>0){var (d,parent)=todo.Pop();Need(seenD.Add(d),"Ciclo de directorios");int o=checked((int)d);Need(o<=dirs.Length-24,"Directorio inválido");string name=Name(dirs,o+24,checked((int)D32(dirs,o+20)));string here=parent.Length==0?name:parent+"/"+name;
            for(uint x=D32(dirs,o+12);x!=uint.MaxValue;){Need(seenF.Add(x),"Ciclo de archivos");int i=checked((int)x);Need(i<=files.Length-32,"Archivo inválido");long off=D64(files,i+8),sz=D64(files,i+16);Need(data<=length&&off<=length-data&&sz<=length-data-off,"Archivo fuera de RomFS");string nm=Name(files,i+32,checked((int)D32(files,i+28)));Need(nm.Length>0,"Nombre vacío");names.Add(here.Length==0?nm:here+"/"+nm);x=D32(files,i+4);}
            var siblings=new HashSet<uint>();for(uint x=D32(dirs,o+8);x!=uint.MaxValue;){Need(siblings.Add(x),"Ciclo de hermanos");int i=checked((int)x);Need(i<=dirs.Length-24,"Hermano inválido");todo.Push((x,here));x=D32(dirs,i+4);}
        }return names.OrderBy(x=>x,StringComparer.Ordinal).ToList();}
    static ulong Fnv(string p){ulong h=1469598103934665603UL;foreach(byte b in Encoding.UTF8.GetBytes(p))h=unchecked((h^b)*1099511628211UL);return h==0?1:h;}
    internal static string Image(string rom,string dst,string gid,IReadOnlyList<(string rel,string path)> others,List<string> names,long prefix=0,string extractedHash=null){
        // Reserve the IMG header during extraction; old standard files still use the backward-copy fallback.
        // Move the private RomFS file into its IMG in place, copying backwards in 4 MiB blocks.
        // This never touches the original NSP/XCI. Avoids a second full-size RomFS allocation.
        var list=Encoding.UTF8.GetBytes(string.Concat(names.Select(n=>n+"\n")));long romLen=new FileInfo(rom).Length-prefix;Need((prefix==0||prefix==Page)&&romLen>=80,"RomFS/prefijo inválido");
        using var identity=IncrementalHash.CreateHash(HashAlgorithmName.SHA256);string romHash=prefix==0?Sha(rom):extractedHash;Need(romHash!=null&&romHash.Length==64&&romHash.All(Uri.IsHexDigit),"Hash RomFS inválido");identity.AppendData(Encoding.ASCII.GetBytes(romHash));foreach(var (rel,path) in others.OrderBy(x=>x.rel,StringComparer.Ordinal)){identity.AppendData(Encoding.UTF8.GetBytes(rel+"\t"+Sha(path)+"\n"));}string pid=Hex(identity.GetHashAndReset());
        File.Move(rom,dst);using var f=new FileStream(dst,FileMode.Open,FileAccess.ReadWrite);if(prefix==0){f.SetLength(checked(romLen+Page));byte[] buf=new byte[4*1024*1024];for(long end=romLen;end>0;){int n=(int)Math.Min(end,buf.Length);long start=end-n;f.Position=start;f.ReadExactly(buf.AsSpan(0,n));f.Position=start+Page;f.Write(buf,0,n);end=start;}}
        f.Position=0;f.Write(new byte[Page]);long pos=Up(Page+romLen);var entries=new List<(string rel,long off,long len)>();foreach(var (rel,path) in others.OrderBy(x=>x.rel,StringComparer.Ordinal)){f.Position=pos;using var src=File.OpenRead(path);long n=src.Length;Copy(src,f,n);entries.Add((rel,pos,n));pos=Up(pos+n);}f.Position=pos;f.Write(list);entries.Add(("romfs.list",pos,list.LongLength));pos=Up(pos+list.LongLength);
        int slots=1;while(slots<Math.Max(1,entries.Count)*2)slots*=2;var tab=new (ulong h,long off,long len,uint po,uint pn)[slots];using var paths=new MemoryStream();foreach(var e in entries.OrderBy(x=>x.rel,StringComparer.Ordinal)){ulong h=Fnv(e.rel);int k=(int)(h&(ulong)(slots-1));while(tab[k].h!=0)k=(k+1)&(slots-1);byte[] p=Encoding.UTF8.GetBytes(e.rel);tab[k]=(h,e.off,e.len,U32(paths.Length),U32(p.Length));paths.Write(p);}
        byte[] toc=B(w=>{w.Write((uint)slots);w.Write((uint)entries.Count);foreach(var t in tab){w.Write(t.h);Q(w,t.off);Q(w,t.len);w.Write(t.po);w.Write(t.pn);}w.Write(paths.ToArray());});f.Position=pos;f.Write(toc);long total=pos+toc.Length;f.SetLength(total);f.Position=0;f.Write(B(w=>{Fixed(w,"S2AIMG01",8);w.Write(1u);w.Write(0u);Fixed(w,gid,16);Fixed(w,pid,64);Q(w,Page);Q(w,romLen);Q(w,pos);Q(w,toc.Length);Q(w,total);}));return pid;
    }
}
