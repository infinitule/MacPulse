// smc.c — minimal AppleSMC reader/writer for MacPulse thermal governor.
// Reads temps + fan RPM/min/max; sets fan minimum floor (safe: SMC keeps its
// auto curve, just never dips below the floor). Restores by writing floor back.
//
// Handles the T2-era (MacBookPro15,1) type zoo: flt (float32), fpe2/fp2e
// (fixed-point unsigned), sp78 (signed fixed 8.8), ui8/ui16/ui32.
//
// build:  clang -O2 -framework IOKit -framework CoreFoundation smc.c -o smc
// usage:  smc temp | smc fans | smc read <KEY> | smc set <KEY> <float>
//
// SMC key writes require root.  Reads do not.
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <stdint.h>
#include <IOKit/IOKitLib.h>

typedef struct { char major, minor, build, reserved[1]; uint16_t release; } SMCVers;
typedef struct { uint16_t version, length; uint32_t cpuPLimit, gpuPLimit, memPLimit; } SMCPLimit;
typedef struct { uint32_t dataSize; uint32_t dataType; uint8_t dataAttributes; } SMCKeyInfo;
typedef struct {
    uint32_t   key;
    SMCVers    vers;
    SMCPLimit  pLimit;
    SMCKeyInfo keyInfo;
    uint8_t    result, status, data8;
    uint32_t   data32;
    uint8_t    bytes[32];
} SMCParam;

enum { KERNEL_INDEX_SMC = 2, SMC_CMD_READ_BYTES = 5, SMC_CMD_WRITE_BYTES = 6, SMC_CMD_READ_KEYINFO = 9 };

static io_connect_t g_conn = 0;

static uint32_t s2k(const char *s){ return ((uint32_t)s[0]<<24)|((uint32_t)s[1]<<16)|((uint32_t)s[2]<<8)|(uint32_t)s[3]; }
static void t2s(uint32_t t, char *o){ o[0]=t>>24; o[1]=t>>16; o[2]=t>>8; o[3]=t; o[4]=0; }

static int smc_open(void){
    io_service_t svc = IOServiceGetMatchingService(kIOMasterPortDefault, IOServiceMatching("AppleSMC"));
    if(!svc) return 1;
    kern_return_t r = IOServiceOpen(svc, mach_task_self(), 0, &g_conn);
    IOObjectRelease(svc);
    return r != kIOReturnSuccess;
}
static void smc_close(void){ if(g_conn) IOServiceClose(g_conn); }

static kern_return_t call(SMCParam *in, SMCParam *out){
    size_t osz = sizeof(SMCParam);
    return IOConnectCallStructMethod(g_conn, KERNEL_INDEX_SMC, in, sizeof(SMCParam), out, &osz);
}

// read raw bytes + type for KEY. returns 0 ok.
static int smc_read(const char *key, uint32_t *type, uint32_t *size, uint8_t *buf){
    SMCParam in, out; memset(&in,0,sizeof in); memset(&out,0,sizeof out);
    in.key = s2k(key); in.data8 = SMC_CMD_READ_KEYINFO;
    if(call(&in,&out) != kIOReturnSuccess || out.result) return 1;
    *type = out.keyInfo.dataType; *size = out.keyInfo.dataSize;
    memset(&in,0,sizeof in);
    in.key = s2k(key); in.keyInfo.dataSize = out.keyInfo.dataSize; in.data8 = SMC_CMD_READ_BYTES;
    if(call(&in,&out) != kIOReturnSuccess || out.result) return 1;
    // Copy using the size learned from READ_KEYINFO — the READ_BYTES response
    // does not reliably echo keyInfo, and trusting it copies 0 bytes and
    // decodes stale stack (which reads as 0.000 for every key).
    if(*size > 32) *size = 32;
    memcpy(buf, out.bytes, *size);
    return 0;
}

// decode a value buffer of the SMC's native type into a double.
static double decode(uint32_t type, uint32_t size, const uint8_t *b){
    char t[5]; t2s(type,t);
    if(!strcmp(t,"flt ")){ float f; memcpy(&f,b,4); return (double)f; }
    if(!strcmp(t,"sp78")){ int16_t v=(b[0]<<8)|b[1]; return v/256.0; }               // signed 8.8
    if(!strcmp(t,"fpe2")){ uint16_t v=(b[0]<<8)|b[1]; return v/4.0; }                 // unsigned 14.2
    if(!strcmp(t,"fp2e")){ uint16_t v=(b[0]<<8)|b[1]; return v/16384.0; }
    if(!strcmp(t,"ui8 ")||!strcmp(t,"ui8")) return b[0];
    if(!strcmp(t,"ui16")) return (b[0]<<8)|b[1];
    if(!strcmp(t,"ui32")) return ((uint32_t)b[0]<<24)|(b[1]<<16)|(b[2]<<8)|b[3];
    // fallback: big-endian integer
    double v=0; for(uint32_t i=0;i<size;i++) v=v*256+b[i]; return v;
}

// encode a double into KEY's native type and write it. returns 0 ok.
static int smc_write(const char *key, double val){
    uint32_t type,size; uint8_t buf[32];
    if(smc_read(key,&type,&size,buf)) return 1;                 // learn type+size
    char t[5]; t2s(type,t);
    uint8_t out[32]; memset(out,0,sizeof out);
    if(!strcmp(t,"flt ")){ float f=(float)val; memcpy(out,&f,4); }
    else if(!strcmp(t,"fpe2")){ uint16_t v=(uint16_t)(val*4.0); out[0]=v>>8; out[1]=v; }
    else if(!strcmp(t,"fp2e")){ uint16_t v=(uint16_t)(val*16384.0); out[0]=v>>8; out[1]=v; }
    else if(!strcmp(t,"sp78")){ int16_t v=(int16_t)(val*256.0); out[0]=v>>8; out[1]=v; }
    else if(!strcmp(t,"ui8 ")||!strcmp(t,"ui8")){ out[0]=(uint8_t)val; }
    else if(!strcmp(t,"ui16")){ uint16_t v=(uint16_t)val; out[0]=v>>8; out[1]=v; }
    else { return 2; }                                          // unknown type: refuse
    SMCParam in,o; memset(&in,0,sizeof in); memset(&o,0,sizeof o);
    in.key=s2k(key); in.data8=SMC_CMD_WRITE_BYTES; in.keyInfo.dataSize=size;
    memcpy(in.bytes,out,size);
    if(call(&in,&o)!=kIOReturnSuccess || o.result) return 3;
    return 0;
}

static double rd(const char *key){
    uint32_t type,size; uint8_t buf[32];
    if(smc_read(key,&type,&size,buf)) return -1;
    return decode(type,size,buf);
}

int main(int argc, char **argv){
    if(smc_open()){ fprintf(stderr,"cannot open AppleSMC\n"); return 1; }
    int rc=0;
    if(argc>=2 && !strcmp(argv[1],"temp")){
        // try a few CPU die/proximity keys; print the hottest valid one
        const char *keys[]={"TC0D","TC0E","TC0F","TC0P","Tp09","Tp0T",0};
        double best=-1; for(int i=0;keys[i];i++){ double v=rd(keys[i]); if(v>0&&v<125&&v>best) best=v; }
        double g=rd("TG0D"); if(g<=0||g>125) g=rd("TGDD");
        printf("{\"cpu\":%.1f,\"gpu\":%.1f}\n", best, g>0?g:0);
    } else if(argc>=2 && !strcmp(argv[1],"fans")){
        int n=(int)rd("FNum"); if(n<0)n=0;
        printf("{\"count\":%d", n);
        for(int i=0;i<n && i<4;i++){
            char a[5],mn[5],mx[5]; snprintf(a,5,"F%dAc",i); snprintf(mn,5,"F%dMn",i); snprintf(mx,5,"F%dMx",i);
            printf(",\"f%d\":{\"rpm\":%.0f,\"min\":%.0f,\"max\":%.0f}", i, rd(a), rd(mn), rd(mx));
        }
        printf("}\n");
    } else if(argc>=2 && !strcmp(argv[1],"tempraw")){
        // plain "cpu gpu" for shell consumption
        const char *keys[]={"TC0D","TC0E","TC0F","TC0P","TCXC","Tp09","Tp0T",0};
        double best=-1; for(int i=0;keys[i];i++){ double v=rd(keys[i]); if(v>0&&v<125&&v>best) best=v; }
        double g=rd("TG0D"); if(g<=0||g>125) g=rd("TGDD"); if(g<=0||g>125) g=rd("TG0P");
        printf("%.1f %.1f\n", best>0?best:0, g>0?g:0);
    } else if(argc>=3 && !strcmp(argv[1],"get")){
        // bare numeric value, "nan" on failure — for shell arithmetic
        uint32_t type,size; uint8_t buf[32];
        if(smc_read(argv[2],&type,&size,buf)){ printf("nan\n"); rc=1; }
        else printf("%.2f\n", decode(type,size,buf));
    } else if(argc>=2 && !strcmp(argv[1],"fanstat")){
        // one line per fan: "<idx> <rpm> <min> <max>" (invalid reads print -1)
        for(int i=0;i<2;i++){
            char a[5],mn[5],mx[5]; snprintf(a,5,"F%dAc",i); snprintf(mn,5,"F%dMn",i); snprintf(mx,5,"F%dMx",i);
            printf("%d %.0f %.0f %.0f\n", i, rd(a), rd(mn), rd(mx));
        }
    } else if(argc>=3 && !strcmp(argv[1],"read")){
        uint32_t type,size; uint8_t buf[32];
        if(smc_read(argv[2],&type,&size,buf)){ printf("ERR\n"); rc=1; }
        else { char t[5]; t2s(type,t); printf("%s type=%s size=%u val=%.3f\n", argv[2], t, size, decode(type,size,buf)); }
    } else if(argc>=4 && !strcmp(argv[1],"set")){
        rc = smc_write(argv[2], atof(argv[3]));
        printf("%s <- %s : %s\n", argv[2], argv[3], rc?"FAIL":"ok");
    } else {
        fprintf(stderr,"usage: smc temp|tempraw|fans|fanstat | get <KEY> | read <KEY> | set <KEY> <float>\n"); rc=2;
    }
    smc_close();
    return rc;
}
