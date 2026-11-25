#include <stdio.h>
#include "rewriter.h"
int converter_rewrite(const char *input,const char *output,const char *module,const char *fix,const char *log){
    FILE *f=fopen(log,"a");if(!f)return 1;setvbuf(f,NULL,_IOLBF,0);
    s2a_rewrite_request r={.input=input,.output_dir=output,.module=module,.target="apple",.spin=1,.fix_tsv=fix};
    int rc=s2a_rewrite_files(&r,f);fclose(f);return rc;
}
