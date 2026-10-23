/* Fixed firmware experiment: RGBA portrait 758x1024 -> 4bpp EBC 1024x758.
 * No device access, allocations or threading here. Calibration is read-only. */
#include <stdint.h>
#include <stddef.h>
#define SW 758
#define SH 1024
#define PITCH 512
static int valid(const void *dst,const void *src,int stride,int inverse,int turn,int high) {
    return dst && src && stride>=SW*4 && stride<=16384 && (inverse==0||inverse==1)
        && (turn==0||turn==1) && (high==0||high==1);
}
static unsigned gray(const uint8_t *p,int inverse) {
    unsigned v=(77u*p[0]+150u*p[1]+29u*p[2]+128u)>>8;
    return (inverse ? 255-v : v)>>4;
}
static size_t address(int x,int y,int turn) {
    /* turn0: (y,757-x); turn1: (1023-y,x). y is always even. */
    return turn ? (size_t)x*PITCH+(1022-y)/2 : (size_t)(757-x)*PITCH+y/2;
}
int tapless_trace_pack(uint8_t *dst,const uint8_t *src,int stride,int inverse,int turn,int high) {
    if (!valid(dst,src,stride,inverse,turn,high)) return -1;
    for (int tx=0;tx<SW;tx+=32) for (int ty=0;ty<SH;ty+=32)
        for (int x=tx;x<SW && x<tx+32;x++) for (int y=ty;y<ty+32;y+=2) {
            unsigned a=gray(src+(size_t)y*stride+4*x,inverse);
            unsigned b=gray(src+(size_t)(y+1)*stride+4*x,inverse);
            /* 'high' means the first logical-y pixel occupies the high nibble. */
            dst[address(x,y,turn)]=(uint8_t)(high ? (a<<4)|b : (b<<4)|a);
        }
    return 0;
}
static unsigned difference(unsigned a,unsigned b) {return a>b?a-b:b-a;}
int tapless_trace_compare(const uint8_t *panel,const uint8_t *src,int stride,int inverse,
                          int turn,int high,uint32_t out[4]) {
    if (!out || !valid(panel,src,stride,inverse,turn,high)) return -1;
    for (int i=0;i<4;i++) out[i]=0;
    /* Static lower keyboard; avoid top text, cursor and Android status elements. */
    for (int x=12;x<SW-12;x++) for (int y=560;y<SH-16;y+=2) {
        unsigned a=gray(src+(size_t)y*stride+4*x,inverse);
        unsigned b=gray(src+(size_t)(y+1)*stride+4*x,inverse);
        unsigned p=panel[address(x,y,turn)],u=high?p>>4:p&15,v=high?p&15:p>>4;
        unsigned error=difference(a,u)+difference(b,v);
        out[0]+=2;out[1]+=error;
        if (difference(a,b)>=4) {out[2]+=2;out[3]+=error;}
    }
    return 0;
}

/* Preserve the coherent cached background, converting the cumulative trace ROI.
 * Packed bytes contain adjacent logical-Y pixels; include both at odd edges. */
int tapless_trace_pack_rect(uint8_t *dst,const uint8_t *src,int stride,int inverse,
                            int turn,int high,int x,int y,int w,int h) {
    if (!valid(dst,src,stride,inverse,turn,high) || x<0 || y<0 || w<=0 || h<=0
        || x>=SW || y>=SH || w>SW-x || h>SH-y) return -1;
    int x2=x+w,y2=(y+h+1)&~1;
    y&=~1;
    for (int tx=x;tx<x2;tx+=32) for (int ty=y;ty<y2;ty+=32) {
        int xe=tx+32<x2?tx+32:x2,ye=ty+32<y2?ty+32:y2;
        for (int sx=tx;sx<xe;sx++) for (int sy=ty;sy<ye;sy+=2) {
            unsigned a=gray(src+(size_t)sy*stride+4*sx,inverse);
            unsigned b=gray(src+(size_t)(sy+1)*stride+4*sx,inverse);
            dst[address(sx,sy,turn)]=(uint8_t)(high ? (a<<4)|b : (b<<4)|a);
        }
    }
    return 0;
}

/* Finish damage is computed after repaint against a pre-clear RGB snapshot.
 * Ignore alpha; snapshot and source must be uint32-aligned RGBA8888. */
#include <string.h>
static int rgb_valid(const void *a,const void *b,int stride) {
    return a && b && !((uintptr_t)a&3) && !((uintptr_t)b&3)
        && stride>=SW*4 && stride<=16384 && !(stride&3);
}
int tapless_finish_snapshot(uint32_t *dst,const uint8_t *src,int stride) {
    if (!rgb_valid(dst,src,stride)) return -1;
    for (int y=0;y<SH;y++) memcpy(dst+(size_t)y*SW,src+(size_t)y*stride,SW*4);
    return 0;
}
int tapless_finish_diff(const uint32_t *before,const uint8_t *src,int stride,int out[5]) {
    if (!out || !rgb_valid(before,src,stride)) return -1;
    int minx=SW,miny=SH,maxx=-1,maxy=-1,count=0;
    for (int y=0;y<SH;y++) {
        const uint32_t *old=before+(size_t)y*SW;
        const uint32_t *row=(const uint32_t *)(src+(size_t)y*stride);
        if (memcmp(old,row,SW*4)==0) continue;
        for (int x=0;x<SW;x++) if ((old[x]^row[x])&0x00ffffffu) {
            if (x<minx) minx=x;
            if (x>maxx) maxx=x;
            if (y<miny) miny=y;
            if (y>maxy) maxy=y;
            count++;
        }
    }
    out[0]=count?minx:0;out[1]=count?miny:0;
    out[2]=count?maxx-minx+1:0;out[3]=count?maxy-miny+1:0;out[4]=count;
    return 0;
}
