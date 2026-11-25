using System;
using System.IO;
using System.Linq;
using System.Text;
using System.Text.Json;
using System.Collections.Generic;
using System.Buffers.Binary;
using System.Runtime.InteropServices;
using ZstdSharp;

internal static class ConvertJob {
    [DllImport("__Internal", EntryPoint="converter_rewrite")]
    static extern int Rewrite([MarshalAs(UnmanagedType.LPUTF8Str)] string input,[MarshalAs(UnmanagedType.LPUTF8Str)] string output,[MarshalAs(UnmanagedType.LPUTF8Str)] string module,[MarshalAs(UnmanagedType.LPUTF8Str)] string fix,[MarshalAs(UnmanagedType.LPUTF8Str)] string log);
    static byte[] Json(Action<Utf8JsonWriter> write){using var m=new MemoryStream();using(var w=new Utf8JsonWriter(m,new JsonWriterOptions{Indented=true})){w.WriteStartObject();write(w);w.WriteEndObject();}return m.ToArray();}
    static void Need(bool ok,string message){if(!ok)throw new InvalidDataException(message);}
    // Avoid System.Formats.Tar.TarHeader.WriteEmptyPadding, whose AOT instruction
    // matches the interrupted frame in the iPhone 17 v0.2 crash report.
    // USTAR regular files only, fixed heap buffers; no stackalloc or span writes.
    sealed class SafeTar {
        readonly Stream output;
        readonly byte[] header=new byte[512], zeros=new byte[1024], buffer=new byte[1024*1024];
        internal SafeTar(Stream output){this.output=output;}
        void Field(int offset,int length,string value){
            byte[] b=Encoding.UTF8.GetBytes(value);
            Need(b.Length<=length,"Campo USTAR demasiado largo");
            Buffer.BlockCopy(b,0,header,offset,b.Length);
        }
        void Octal(int offset,int length,long value){
            Need(value>=0,"Valor USTAR negativo");
            string digits=Convert.ToString(value,8);
            Need(digits.Length<length,"Valor USTAR fuera de rango");
            Field(offset,length-1,digits.PadLeft(length-1,'0'));
        }
        internal void Add(string name,Stream data){
            Need(data.CanSeek&&data.Position==0,"Entrada USTAR inválida");
            long size=data.Length;
            Array.Clear(header,0,header.Length);
            string leaf=name,prefix="";
            if(Encoding.UTF8.GetByteCount(name)>100){
                int k=name.LastIndexOf('/');
                while(k>0){
                    if(Encoding.UTF8.GetByteCount(name.Substring(k+1))<=100&&Encoding.UTF8.GetByteCount(name.Substring(0,k))<=155){leaf=name.Substring(k+1);prefix=name.Substring(0,k);break;}
                    k=name.LastIndexOf('/',k-1);
                }
                Need(k>0,"Ruta USTAR demasiado larga");
            }
            Field(0,100,leaf);Octal(100,8,420);Octal(108,8,0);Octal(116,8,0);Octal(124,12,size);Octal(136,12,0);
            for(int i=148;i<156;i++)header[i]=32;
            header[156]=(byte)'0';Field(257,6,"ustar");Field(263,2,"00");Octal(329,8,0);Octal(337,8,0);Field(345,155,prefix);
            int checksum=0;foreach(byte v in header)checksum+=v;
            Field(148,6,Convert.ToString(checksum,8).PadLeft(6,'0'));header[154]=0;header[155]=32;
            output.Write(header,0,512);
            long left=size;
            while(left>0){int n=data.Read(buffer,0,(int)Math.Min(buffer.Length,left));Need(n>0,"Entrada USTAR truncada");output.Write(buffer,0,n);left-=n;}
            int pad=(int)((512-size%512)%512);if(pad!=0)output.Write(zeros,0,pad);
        }
        internal void Finish()=>output.Write(zeros,0,1024);
    }
    // Emit a real GPU-driver list from the rewritten, decompressed image. The
    // upstream classifier chooses the lexically first NintendoSDK component.
    internal static string DriverTable(string rw,IEnumerable<string> mods){
        var output=new List<string>();
        foreach(string m in mods.OrderBy(x=>x,StringComparer.Ordinal)){
            if(m=="main"||m=="sdk"||m=="rtld")continue;
            using var f=File.OpenRead(Path.Combine(rw,m+".patched.bin"));
            var components=new SortedSet<string>(StringComparer.Ordinal);
            // Keep memory bounded. Carry an incomplete ASCII component token
            // across reads; never interpret compressed NSO bytes as metadata.
            var token=new StringBuilder(128);
            const string prefix="NintendoSDK_";int matched=0,phase=0;
            bool Word(int b)=>(b>=65&&b<=90)||(b>=97&&b<=122)||(b>=48&&b<=57)||b==95;
            bool Version(int b)=>(b>=48&&b<=57)||b==95;
            void Finish(){if(phase==3&&token.Length>prefix.Length&&!token.ToString().StartsWith("NintendoSDK_nnSdk",StringComparison.Ordinal))components.Add(token.ToString());phase=matched=0;token.Clear();}
            var buf=new byte[1024*1024];
            int n;
            while((n=f.Read(buf,0,buf.Length))>0)for(int i=0;i<n;i++){
                int b=buf[i];
                if(phase==1&&Word(b)){if(token.Length>=4096)throw new InvalidDataException("Componente SDK demasiado largo");token.Append((char)b);continue;}
                if(phase==1&&b==45&&token.Length>prefix.Length){phase=2;continue;}
                if((phase==2||phase==3)&&Version(b)){phase=3;continue;}
                if(phase!=0)Finish();
                if(b==prefix[matched]){if(++matched==prefix.Length){token.Append(prefix);phase=1;matched=0;}}else matched=b==prefix[0]?1:0;
            }
            Finish();
            if(components.Min=="NintendoSDK_OpenGL"||components.Min=="NintendoSDK_Vulkan")output.Add(m);
        }
        return string.Join("\n",output)+"\n";
    }
    static void TarBytes(SafeTar t,string name,byte[] bytes){using var m=new MemoryStream(bytes,false);t.Add(name,m);}
    internal static int ModuleRank(string m)=>m=="main"?0:m=="sdk"?11:m.Length==7&&m.StartsWith("subsdk",StringComparison.Ordinal)&&m[6]>='0'&&m[6]<='9'?1+m[6]-'0':-1;
    internal static void WritePackage(string outFile,string gid,string title,string version,string imageName,string sha,string pid,long size,List<(string name,string path)> entries,bool hasIcon){
        var table="program/Games/"+gid+"/gpu_drivers.tsv";
        if(!entries.Any(e=>e.name==table)){
            string rw=Path.Combine(Path.GetDirectoryName(entries.First(e=>e.name=="program/"+imageName).path)!,"rewrite");
            var mods=entries.Where(e=>e.name.EndsWith(".fixups.tsv",StringComparison.Ordinal)).Select(e=>Path.GetFileName(e.name).Replace(".fixups.tsv","")).ToList();
            string path=Path.Combine(rw,"gpu_drivers.tsv");File.WriteAllText(path,DriverTable(rw,mods),new UTF8Encoding(false));entries.Add((table,path));
        }
        var index=Encoding.UTF8.GetBytes($"game.img\t{size}\t{pid}\n");string indexSha=ConverterFormats.Sha(index);var manifest=Json(w=>{w.WriteNumber("version",3);w.WriteString("format","img");w.WriteString("imgFile","game.img");w.WriteNumber("files",1);w.WriteNumber("total",size);w.WriteString("index_sha256",indexSha);});
        void Common(Utf8JsonWriter w){w.WriteString("title_id",gid);w.WriteString("name",title);w.WriteString("display_version",version);w.WriteNumber("host_abi",GeneratedVersion.HostAbi);w.WriteString("chain",GeneratedVersion.Chain);w.WriteString("rewriter_id",GeneratedVersion.Rewriter);w.WriteString("image",imageName);w.WriteString("image_sha256",sha);}
        var cat=Json(w=>{w.WriteNumber("schema",1);Common(w);w.WriteNull("team");if(hasIcon)w.WriteString("icon","Games/"+gid+"/icon.jpg");});long total=cat.LongLength+index.LongLength+manifest.LongLength+entries.Sum(e=>new FileInfo(e.path).Length);
        var head=Json(w=>{w.WriteString("format","s2arm");w.WriteNumber("schema",1);Common(w);w.WriteString("source_sha256",sha);w.WriteString("pack",indexSha);w.WriteNumber("bytes",total);w.WriteNull("signer");});
        using(var file=File.Create(outFile))using(var z=new CompressionStream(file,3)){
            z.SetParameter(ZstdSharp.Unsafe.ZSTD_cParameter.ZSTD_c_checksumFlag,1);
            var tar=new SafeTar(z);
            Console.WriteLine("[USTAR] s2arm.json");TarBytes(tar,"s2arm.json",head);
            Console.WriteLine("[USTAR] program/catalogue.json");TarBytes(tar,"program/catalogue.json",cat);
            foreach(var e in entries){Console.WriteLine("[USTAR] "+e.name);using var stream=File.OpenRead(e.path);tar.Add(e.name,stream);}
            TarBytes(tar,"pack/index.tsv",index);TarBytes(tar,"pack/manifest.json",manifest);tar.Finish();
            Console.WriteLine("[USTAR] Finalizando zstd");
        }
        Console.WriteLine("[USTAR] Paquete completo");
    }
    static string Publish(string docs,string work,string gid){
        string dest=Path.Combine(docs,"Converted",gid+"-"+DateTime.UtcNow.ToString("yyyyMMdd-HHmmss")+"-"+Guid.NewGuid().ToString("N").Substring(0,6));
        Directory.CreateDirectory(Path.GetDirectoryName(dest)!);Directory.Move(Path.Combine(work,"result"),dest);
        try{Directory.Delete(work,true);}catch{}
        return dest;
    }
    // Explicit recovery of v0.2 or v0.3 work after the resource image was fully written.
    // Validate actual IMG header, TOC bounds, title ID and executable/table inventory.
    internal static string RecoverableWork(string docs){
        if(!Directory.Exists(docs))return null;
        foreach(var work in Directory.GetDirectories(docs,".work-*").OrderByDescending(p=>Directory.GetLastWriteTimeUtc(p))){
            try{
                string result=Path.Combine(work,"result");
                if(!Directory.Exists(result))continue;
                var imgs=Directory.GetFiles(result,"*.img");if(imgs.Length!=1)continue;
                string gid=Path.GetFileNameWithoutExtension(imgs[0]);
                if(gid.Length!=16||gid.Any(c=>!Uri.IsHexDigit(c)))continue;
                using var file=File.OpenRead(imgs[0]);byte[] h=new byte[136];file.ReadExactly(h);
                if(Encoding.ASCII.GetString(h,0,8)!="S2AIMG01"||BinaryPrimitives.ReadUInt32LittleEndian(h.AsSpan(8,4))!=1||Encoding.ASCII.GetString(h,16,16)!=gid)continue;
                long ro=BinaryPrimitives.ReadInt64LittleEndian(h.AsSpan(96,8)),rs=BinaryPrimitives.ReadInt64LittleEndian(h.AsSpan(104,8)),to=BinaryPrimitives.ReadInt64LittleEndian(h.AsSpan(112,8)),ts=BinaryPrimitives.ReadInt64LittleEndian(h.AsSpan(120,8)),total=BinaryPrimitives.ReadInt64LittleEndian(h.AsSpan(128,8));
                if(total!=file.Length||ro!=16384||rs<80||rs>total-ro||to<ro+rs||ts<8||ts>total||to!=total-ts)continue;
                if(!File.Exists(Path.Combine(work,"S2AImages-"+gid+".dylib"))||!File.Exists(Path.Combine(work,"unpack","unpack.tsv"))||!File.Exists(Path.Combine(work,"unpack","exefs","main.npdm")))continue;
                return work;
            }catch(IOException){}catch(UnauthorizedAccessException){}
        }
        return null;
    }
    internal static string Recover(string docs,Action<string> progress){
        string work=RecoverableWork(docs);Need(work!=null,"No hay una conversión anterior con IMG completo.");
        string root=Path.Combine(work,"unpack"),rw=Path.Combine(work,"rewrite"),result=Path.Combine(work,"result");
        string img=Directory.GetFiles(result,"*.img").Single(),gid=Path.GetFileNameWithoutExtension(img),imageName="S2AImages-"+gid+".dylib",dylib=Path.Combine(work,imageName);
        var oldOut=Console.Out;var oldErr=Console.Error;
        using var logger=new StreamWriter(Path.Combine(docs,"last-conversion.log"),true,new UTF8Encoding(false)){AutoFlush=true};
        try{
            Console.SetOut(logger);Console.SetError(logger);
            Console.WriteLine("[RECOVERY] "+gid);progress("Recuperando paquete anterior…");
            byte[] np=File.ReadAllBytes(Path.Combine(root,"exefs","main.npdm"));
            Need(np.Length>=128&&Encoding.ASCII.GetString(np,0,4)=="META","NPDM inválido");
            int aci=checked((int)BinaryPrimitives.ReadUInt32LittleEndian(np.AsSpan(0x70,4)));
            Need(aci>=0&&aci<=np.Length-24&&Encoding.ASCII.GetString(np,aci,4)=="ACI0"&&BinaryPrimitives.ReadUInt64LittleEndian(np.AsSpan(aci+16,8)).ToString("X16")==gid,"El IMG no coincide con el programa");
            string pid;long size;using(var input=File.OpenRead(img)){byte[] h=new byte[136];input.ReadExactly(h);pid=Encoding.ASCII.GetString(h,32,64);size=input.Length;}
            var mods=Directory.GetFiles(Path.Combine(root,"exefs")).Select(Path.GetFileName).Where(m=>ModuleRank(m)>=0).OrderBy(ModuleRank).ToList();
            Need(mods.Contains("main"),"Falta el módulo principal");
            var entries=new List<(string name,string path)>{("program/"+imageName,dylib),("program/Games/"+gid+"/main.npdm",Path.Combine(root,"exefs","main.npdm"))};
            foreach(var m in mods)foreach(var suf in new[]{".fixups.tsv",".gates.tsv"}){string p=Path.Combine(rw,m+suf);Need(File.Exists(p),"Falta tabla "+m+suf);entries.Add(("program/Games/"+gid+"/"+m+suf,p));}
            string icon=Path.Combine(root,"icon.jpg");if(File.Exists(icon))entries.Add(("program/Games/"+gid+"/icon.jpg",icon));
            var meta=new Dictionary<string,string>();foreach(var line in File.ReadLines(Path.Combine(root,"unpack.tsv"))){int i=line.IndexOf('\t');if(i>0)meta.TryAdd(line[..i],line[(i+1)..]);}
            Need(meta.GetValueOrDefault("title_id","").Equals(gid,StringComparison.OrdinalIgnoreCase),"Metadatos de recuperación no coinciden");
            WritePackage(Path.Combine(result,gid+".s2arm"),gid,meta.GetValueOrDefault("name",gid),meta.GetValueOrDefault("display_version",""),imageName,ConverterFormats.Sha(dylib),pid,size,entries,File.Exists(icon));
            return Publish(docs,work,gid);
        }catch(Exception e){logger.WriteLine(e.ToString());throw;}finally{Console.SetOut(oldOut);Console.SetError(oldErr);}
    }
    internal static string Run(string keys,string game,string docs,string bundle,Action<string> progress){
        Need(File.Exists(keys)&&File.Exists(game),"No se pudo acceder a los archivos seleccionados.");
        Need(new[]{".nsp",".xci"}.Contains(Path.GetExtension(game).ToLowerInvariant()),"Seleccioná un NSP o XCI de Switch.");
        string work=Path.Combine(docs,".work-"+Guid.NewGuid().ToString("N")),root=Path.Combine(work,"unpack"),rw=Path.Combine(work,"rewrite"),outdir=Path.Combine(work,"result");
        Directory.CreateDirectory(root);Directory.CreateDirectory(rw);Directory.CreateDirectory(outdir);
        string log=Path.Combine(docs,"last-conversion.log");var oldOut=Console.Out;var oldErr=Console.Error;
        using var logger=new StreamWriter(log,false,new UTF8Encoding(false)){AutoFlush=true};
        void Phase(string label){logger.WriteLine(DateTime.UtcNow.ToString("O")+" "+label);progress(label);}
        try {Console.SetOut(logger);Console.SetError(logger);
            Phase("Extrayendo el juego…");Environment.SetEnvironmentVariable("S2A_ROMFS_IMAGE","1");RomfsExtraction.A19ReserveImageHeader=true;RomfsExtraction.A19ImageHash=null;
            int rc=P.ConvertMain(new[]{keys,root,"--base-only",game});Need(rc==0,$"Extracción fallida ({rc}). Ver last-conversion.log.");
            Phase("Extracción completa; leyendo metadatos…");
            var npdm=Path.Combine(root,"exefs","main.npdm");byte[] np=File.ReadAllBytes(npdm);Need(np.Length>=0x80&&Encoding.ASCII.GetString(np,0,4)=="META"&&(np[0x0c]&1)!=0,"Se requiere un juego ARM64.");
            int aci=checked((int)BinaryPrimitives.ReadUInt32LittleEndian(np.AsSpan(0x70,4)));Need(aci>=0&&aci<=np.Length-24&&Encoding.ASCII.GetString(np,aci,4)=="ACI0","NPDM inválido.");string gid=BinaryPrimitives.ReadUInt64LittleEndian(np.AsSpan(aci+16,8)).ToString("X16");
            string rom=Path.Combine(root,"romfs.std");Need(File.Exists(rom),"No se generó RomFS estándar.");var names=ConverterFormats.RomNames(rom,0x4000);Need(!names.Any(n=>n.EndsWith(".nro",StringComparison.OrdinalIgnoreCase)||n.EndsWith(".nrr",StringComparison.OrdinalIgnoreCase)),"Esta versión mínima no admite módulos NRO/NRR adicionales.");
            var mods=new List<string>();foreach(var p in Directory.GetFiles(Path.Combine(root,"exefs")).OrderBy(x=>x,StringComparer.Ordinal)){string m=Path.GetFileName(p);if(ModuleRank(m)<0)continue;using var f=File.OpenRead(p);byte[] magic=new byte[4];if(f.Read(magic,0,4)!=4||Encoding.ASCII.GetString(magic)!="NSO0")continue;mods.Add(m);}
            Need(mods.Contains("main"),"Falta el NSO principal.");mods=mods.OrderBy(ModuleRank).ToList();
            string fix=null;using(var main=File.OpenRead(Path.Combine(root,"exefs","main"))){main.Position=0x40;var b=new byte[8];main.ReadExactly(b);string candidate=Path.Combine(bundle,"fix",Convert.ToHexString(b).ToLowerInvariant()+".tsv");if(File.Exists(candidate))fix=candidate;}
            foreach(string m in mods){Phase("Convirtiendo código: "+m);rc=Rewrite(Path.Combine(root,"exefs",m),rw,m,fix,Path.Combine(docs,"last-rewrite.log"));logger.WriteLine("Rewriter "+m+" rc="+rc);if(rc==3&&File.Exists(Path.Combine(rw,m+".patched.bin"))){logger.WriteLine($"Advertencia: {m} tiene huecos de traducción; el juego podría fallar.");}else if(rc!=0){string p=Path.Combine(docs,"last-rewrite.log");if(File.Exists(p))logger.WriteLine(File.ReadAllText(p));throw new InvalidDataException($"Reescritura de {m} fallida ({rc}).");}}
            var meta=new Dictionary<string,string>();foreach(var line in File.ReadLines(Path.Combine(root,"unpack.tsv"))){int i=line.IndexOf('\t');if(i>0)meta.TryAdd(line[..i],line[(i+1)..]);}string title=meta.GetValueOrDefault("name",gid),version=meta.GetValueOrDefault("display_version","");
            Phase("Generando programa S2Arm…");string imageName=$"S2AImages-{gid}.dylib",dylib=Path.Combine(work,imageName);ConverterFormats.Dylib(rw,dylib,mods);string sha=ConverterFormats.Sha(dylib);
            var entries=new List<(string name,string path)>{("program/"+imageName,dylib),("program/Games/"+gid+"/main.npdm",npdm)};foreach(var m in mods)foreach(var suffix in new[]{".fixups.tsv",".gates.tsv"}){var p=Path.Combine(rw,m+suffix);Need(File.Exists(p),"Falta tabla del rewriter: "+m+suffix);entries.Add(("program/Games/"+gid+"/"+m+suffix,p));}
            string icon=Path.Combine(root,"icon.jpg");if(File.Exists(icon))entries.Add(("program/Games/"+gid+"/icon.jpg",icon));
            Phase("Preparando imagen de recursos…");var extras=new List<(string rel,string path)>{("exefs/main.npdm",npdm)};var nacp=Path.Combine(root,"ctl","control.nacp");if(File.Exists(nacp))extras.Add(("ctl/control.nacp",nacp));string sys=Path.Combine(bundle,"systemdata");Need(Directory.Exists(sys),"Faltan datos de sistema en el conversor.");foreach(var p in Directory.EnumerateFiles(sys,"*",SearchOption.AllDirectories))extras.Add(("systemdata/"+Path.GetRelativePath(sys,p).Replace('\\','/'),p));string img=Path.Combine(outdir,gid+".img");string pid=ConverterFormats.Image(rom,img,gid,extras,names,0x4000,RomfsExtraction.A19ImageHash);long size=new FileInfo(img).Length;
            Phase("IMG completo; comprimiendo paquete…");WritePackage(Path.Combine(outdir,gid+".s2arm"),gid,title,version,imageName,sha,pid,size,entries,File.Exists(icon));
            Phase("Paquete completo");return Publish(docs,work,gid);
        } catch(Exception e){logger.WriteLine(e.ToString());if(RecoverableWork(docs)!=work){try{Directory.Delete(work,true);}catch{}}throw;} finally {RomfsExtraction.A19ReserveImageHeader=false;RomfsExtraction.A19ImageHash=null;Console.SetOut(oldOut);Console.SetError(oldErr);}
    }
}
