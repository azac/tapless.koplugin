/* Whole-path candidate scan. Same order, bounds and floating point operations
 * as shape_channel.lua and GeometryReranker:scorePathUntil.
 * All storage is owned and anchored by Lua FFI; no native allocation/finalizer. */
#include "shape.h"
#include <math.h>
#include <string.h>

int ts_abi_version(void) { return 2; }
int ts_state_size(void) { return sizeof(TSShapeState); }
int ts_entry_size(void) { return sizeof(TSShapeEntry); }
int ts_word_slot_size(void) { return sizeof(TSWordSlot); }
int ts_signature_slot_size(void) { return sizeof(TSSignatureSlot); }
int ts_hit_size(void) { return sizeof(TSShapeHit); }

static double min(double a, double b) { return a < b ? a : b; }
static double max(double a, double b) { return a > b ? a : b; }
static double distance(const TSShapeCenter *a, const TSShapeCenter *b) {
    double dx = a->x - b->x, dy = a->y - b->y;
    return sqrt(dx * dx + dy * dy);
}
static unsigned int hash_string(const char *key, int length) {
    unsigned int h = 2166136261u;
    for (int i = 0; i < length; ++i) h = (h ^ (unsigned char)key[i]) * 16777619u;
    return h;
}
/* Return 1 for an already seen word, 0 after inserting it, -1 if full. */
static int seen_word(TSShapeState *s, const char *key, int length) {
    unsigned int h = hash_string(key, length), mask = (unsigned int)s->capacity - 1;
    for (unsigned int n = 0, i = h & mask; n < (unsigned int)s->capacity; ++n, i = (i+1)&mask) {
        TSWordSlot *p = &s->words[i];
        if (p->generation!=s->generation) { p->key=key; p->length=length; p->hash=h; p->generation=s->generation; return 0; }
        if (p->hash==h && p->length==length && memcmp(p->key,key,length)==0) return 1;
    }
    return -1;
}
static TSSignatureSlot *signature_slot(TSShapeState *s, const char *key, int length) {
    unsigned int h=hash_string(key,length), mask=(unsigned int)s->capacity-1;
    for (unsigned int n=0, i=h&mask; n<(unsigned int)s->capacity; ++n, i=(i+1)&mask) {
        TSSignatureSlot *p=&s->signatures[i];
        if (p->generation!=s->generation) { p->key=key; p->length=length; p->hash=h; p->generation=s->generation; p->has_shape=0; p->has_bound=0; return p; }
        if (p->hash==h && p->length==length && memcmp(p->key,key,length)==0) return p;
    }
    return 0;
}
static void measure(TSShapeState *s, TSShapeEntry *e) {
    e->measured=1; e->length=0; e->scale=0;
    if (e->signature_length<2) return;
    double total=0, size=0;
    const TSShapeCenter *previous=0;
    for (int i=0; i<e->signature_length; ++i) {
        int c=(unsigned char)e->signature[i]-97;
        if (c<0 || c>=26 || !s->centers[c].present) return;
        const TSShapeCenter *center=&s->centers[c];
        size=size+max(1,center->size);
        if (previous) total=total+distance(previous,center);
        previous=center;
    }
    if (total>0) { e->length=total; e->scale=size/e->signature_length; }
}
static int score(TSShapeState *s, TSShapeEntry *e, int has_worst, double worst, double *value) {
    int segment=1;
    double passed=0, total=0;
    const TSShapeCenter *a=&s->centers[(unsigned char)e->signature[0]-97];
    const TSShapeCenter *b=&s->centers[(unsigned char)e->signature[1]-97];
    double segment_length=distance(a,b);
    double length_term=min(s->max_score,fabs(s->length-e->length)/max(e->scale,e->length))*0.15;
    for (int i=0; i<s->samples; ++i) {
        double target=e->length*i/(s->samples-1);
        while (segment<e->signature_length-1 && passed+segment_length<target) {
            passed=passed+segment_length; ++segment;
            a=b; b=&s->centers[(unsigned char)e->signature[segment]-97];
            segment_length=distance(a,b);
        }
        double ratio=segment_length>0 ? (target-passed)/segment_length : 0;
        double dx=s->x[i]-(a->x+(b->x-a->x)*ratio);
        double dy=s->y[i]-(a->y+(b->y-a->y)*ratio);
        total=total+sqrt(dx*dx+dy*dy);
        double bound=min(s->max_score,total/s->samples/e->scale*0.85+length_term);
        if (bound>s->max_shape || (has_worst && s->shape_weight*bound-e->frequency>=worst)) {
            *value=bound; return 0;
        }
    }
    *value=min(s->max_score,total/s->samples/e->scale*0.85+length_term);
    return 1;
}
int ts_shape_scan(TSShapeState *s, TSShapeEntry *entries, int count, int group, int offset) {
    if (s->samples<2 || s->samples>64 || s->keep<1 || s->keep>64 || s->capacity<1
        || (s->capacity&(s->capacity-1)) || !s->words || !s->signatures || !s->hits) {
        s->overflow=1; return 0;
    }
    int processed=0;
    for (int i=0; i<count; ++i) {
        if (s->entries>=s->max_entries || s->exhausted) { s->exhausted=1; break; }
        ++s->entries; ++processed;
        TSShapeEntry *e=&entries[i];
        if (!e->enabled || !e->word) continue;
        int seen=seen_word(s,e->word,e->word_length);
        if (seen<0) { s->overflow=1; break; }
        if (seen) continue;
        if (!e->signature || e->minimum_length<s->min_letters) continue;
        if (!e->measured) measure(s,e);
        if (e->length<=0) continue;
        double ratio=s->length/e->length;
        if (ratio<s->min_ratio || ratio>s->max_ratio) continue;
        if (s->compared>=s->max_comparisons) { s->exhausted=1; continue; }
        ++s->compared;
        TSSignatureSlot *cache=signature_slot(s,e->signature,e->signature_length);
        if (!cache) { s->overflow=1; break; }
        double shape;
        if (cache->has_shape) shape=cache->shape;
        else {
            int has_worst=s->count>=s->keep;
            double worst=has_worst ? s->hits[s->keep-1].rank : 0;
            if (cache->has_bound && (cache->bound>s->max_shape
                || (has_worst && s->shape_weight*cache->bound-e->frequency>=worst))) continue;
            if (!score(s,e,has_worst,worst,&shape)) {
                cache->bound=cache->has_bound ? max(cache->bound,shape) : shape;
                cache->has_bound=1; continue;
            }
            cache->shape=shape; cache->has_shape=1;
        }
        if (shape>s->max_shape) continue;
        double rank=s->shape_weight*shape-e->frequency;
        int position=s->count;
        while (position>0 && s->hits[position-1].rank>rank) --position;
        if (position<s->keep) {
            int last=s->count<s->keep ? s->count : s->keep-1;
            for (int j=last; j>position; --j) s->hits[j]=s->hits[j-1];
            s->hits[position]=(TSShapeHit){group,offset+i,shape,rank};
            if (s->count<s->keep) ++s->count;
        }
    }
    return processed;
}
